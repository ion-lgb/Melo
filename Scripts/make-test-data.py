#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成用于开发/演示的「与原版兼容」的 LxDatas 测试数据目录。

用法:
  python3 Scripts/make-test-data.py [输出目录] [--source <自定义源.js>] [--no-api-source]

默认输出目录: /tmp/melo-test-data
生成结构（可直接用 MELO_DATA_DIR=<输出目录> 启动 Melo）:
  <dir>/LxDatas/lx.data.db        # 原版 9 表 + 3 索引（原 DDL），WAL
  <dir>/LxDatas/config_v2.json    # { "setting": {...} }
  <dir>/LxDatas/user_api.json     # { "userApis": [...] }，脚本为 gz_ + base64(zlib deflate)
"""
import base64
import json
import os
import sqlite3
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_SOURCE = os.path.join(ROOT, "TestAssets", "demo-source.js")
SAMPLE_MUSIC = os.path.join(ROOT, "TestAssets", "sample-music-info.json")

DDL = [
    '''CREATE TABLE "db_info" (
    "id" INTEGER NOT NULL UNIQUE,
    "field_name" TEXT,
    "field_value" TEXT,
    PRIMARY KEY("id" AUTOINCREMENT)
  );''',
    '''CREATE TABLE "my_list" (
    "id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "source" TEXT,
    "sourceListId" TEXT,
    "position" INTEGER NOT NULL,
    "locationUpdateTime" INTEGER,
    PRIMARY KEY("id")
  );''',
    '''CREATE TABLE "my_list_music_info" (
    "id" TEXT NOT NULL,
    "listId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "singer" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "interval" TEXT,
    "meta" TEXT NOT NULL,
    UNIQUE("id","listId")
  );''',
    '''CREATE INDEX "index_my_list_music_info" ON "my_list_music_info" (
    "id",
    "listId"
  );''',
    '''CREATE TABLE "my_list_music_info_order" (
    "listId" TEXT NOT NULL,
    "musicInfoId" TEXT NOT NULL,
    "order" INTEGER NOT NULL
  );''',
    '''CREATE INDEX "index_my_list_music_info_order" ON "my_list_music_info_order" (
    "listId",
    "musicInfoId"
  );''',
    '''CREATE TABLE "music_info_other_source" (
    "source_id" TEXT NOT NULL,
    "id" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "singer" TEXT NOT NULL,
    "meta" TEXT NOT NULL,
    "order" INTEGER NOT NULL,
    UNIQUE("source_id","id")
  );''',
    '''CREATE INDEX "index_music_info_other_source" ON "music_info_other_source" (
    "source_id",
    "id"
  );''',
    '''CREATE TABLE "lyric" (
    "id" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "text" TEXT NOT NULL
  );''',
    '''CREATE TABLE "music_url" (
    "id" TEXT NOT NULL,
    "url" TEXT NOT NULL
  );''',
    '''CREATE TABLE "download_list" (
    "id" TEXT NOT NULL,
    "isComplate" INTEGER NOT NULL,
    "status" TEXT NOT NULL,
    "statusText" TEXT NOT NULL,
    "progress_downloaded" INTEGER NOT NULL,
    "progress_total" INTEGER NOT NULL,
    "url" TEXT,
    "quality" TEXT NOT NULL,
    "ext" TEXT NOT NULL,
    "fileName" TEXT NOT NULL,
    "filePath" TEXT NOT NULL,
    "musicInfo" TEXT NOT NULL,
    "position" INTEGER NOT NULL,
    PRIMARY KEY("id")
  );''',
    '''CREATE TABLE "dislike_list" (
    "type" TEXT NOT NULL,
    "content" TEXT NOT NULL,
    "meta" TEXT
  );''',
]

LYRIC = """[ti:Melo 测试音频]
[ar:Melo]
[00:00.00]Melo 测试音频 · 第一行
[00:02.00]这是直接写入原版数据库的歌词
[00:04.00]用于验证歌词缓存读取与高亮
[00:06.00]如果显示正常说明数据兼容已打通
[00:08.00]Melo for macOS
"""


def insert_music(conn, list_id, music, order):
    meta = dict(music.get("meta") or {})
    conn.execute(
        'INSERT OR REPLACE INTO my_list_music_info (id, listId, name, singer, source, interval, meta) VALUES (?,?,?,?,?,?,?)',
        (music["id"], list_id, music["name"], music.get("singer") or "", music.get("source") or "",
         music.get("interval"), json.dumps(meta, ensure_ascii=False, separators=(",", ":"))),
    )
    conn.execute(
        'INSERT OR REPLACE INTO my_list_music_info_order (listId, musicInfoId, "order") VALUES (?,?,?)',
        (list_id, music["id"], order),
    )


def main():
    args = [a for a in sys.argv[1:]]
    out = "/tmp/melo-test-data"
    source_path = DEFAULT_SOURCE
    use_api_source = True
    i = 0
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source_path = args[i + 1]
            i += 2
        elif args[i] == "--no-api-source":
            use_api_source = False
            i += 1
        else:
            out = args[i]
            i += 1

    with open(SAMPLE_MUSIC, encoding="utf-8") as f:
        samples = json.load(f)

    lx = os.path.join(out, "LxDatas")
    os.makedirs(lx, exist_ok=True)
    db_path = os.path.join(lx, "lx.data.db")
    if os.path.exists(db_path):
        os.remove(db_path)
    for suffix in ("-wal", "-shm"):
        p = db_path + suffix
        if os.path.exists(p):
            os.remove(p)

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    for statement in DDL:
        conn.execute(statement)
    conn.execute("INSERT INTO db_info (field_name, field_value) VALUES ('version', '2')")

    # 用户列表
    conn.execute(
        "INSERT INTO my_list (id, name, source, sourceListId, position, locationUpdateTime) VALUES (?,?,?,?,?,?)",
        ("testlist", "Melo 测试列表", None, None, 0, None),
    )
    conn.execute(
        "INSERT INTO my_list (id, name, source, sourceListId, position, locationUpdateTime) VALUES (?,?,?,?,?,?)",
        ("testlist2", "Mac 原生", None, None, 1, None),
    )

    # 试听列表 / 收藏 / 临时列表（原版内置列表也从同一张表读）
    for idx, music in enumerate(samples[:3]):
        insert_music(conn, "default", music, idx)
    insert_music(conn, "love", samples[0], 2)
    insert_music(conn, "love", samples[3], 0)
    insert_music(conn, "love", samples[1], 1)
    insert_music(conn, "temp", samples[2], 0)
    for idx, music in enumerate(samples):
        insert_music(conn, "testlist", music, idx)
    for idx, music in enumerate(samples[:2]):
        insert_music(conn, "testlist2", music, idx)

    # 歌词缓存（原版 lyric 表：source='raw'，type=lyric）
    # 原版 lyric.text 存的是 base64(UTF-8)
    lyric_b64 = base64.b64encode(LYRIC.encode("utf-8")).decode("ascii")
    for music in samples:
        conn.execute(
            "INSERT INTO lyric (id, source, type, text) VALUES (?,?,?,?)",
            (music["id"], "raw", "lyric", lyric_b64),
        )

    conn.commit()
    conn.close()

    # 自定义源（gz_ 格式）
    source_id = "user_api_demo_" + str(int(time.time() * 1000))
    with open(source_path, encoding="utf-8") as f:
        script = f.read()
    gz = "gz_" + base64.b64encode(zlib.compress(script.encode("utf-8"))).decode("ascii")
    user_apis = {
        "userApis": [
            {
                "id": source_id,
                "name": "Melo 测试源",
                "description": "本地联调用的测试源（仅测试）",
                "author": "Melo",
                "homepage": "http://127.0.0.1:27331",
                "version": "1.0.0",
                "allowShowUpdateAlert": False,
                "script": gz,
            }
        ]
    }
    with open(os.path.join(lx, "user_api.json"), "w", encoding="utf-8") as f:
        json.dump(user_apis, f, ensure_ascii=False, indent=2)

    # 设置（原版结构：{ "setting": {...} }）
    with open(os.path.join(ROOT, "Resources", "default-settings.json"), encoding="utf-8") as f:
        defaults = json.load(f)
    setting = dict(defaults)
    setting.update({
        "theme.id": "green",
        "common.langId": "zh-cn",
        "player.volume": 0.8,
        "player.playQuality": "128k",
        "common.apiSource": source_id if use_api_source else "temp",
    })
    with open(os.path.join(lx, "config_v2.json"), "w", encoding="utf-8") as f:
        json.dump({"setting": setting}, f, ensure_ascii=False, indent=2)

    print(f"测试数据已生成: {lx}")
    print(f"  数据库: lx.data.db（9 表 3 索引，5 个列表/若干歌曲/歌词缓存）")
    print(f"  设置: config_v2.json")
    print(f"  自定义源: user_api.json（{source_id}）")
    print()
    print("启动 Melo:")
    print(f"  MELO_DATA_DIR={out} MELO_RESOURCES={ROOT}/Resources swift run Melo")
    print(f"  或 MELO_DATA_DIR={out} open build/Melo.app")
    print()
    print("提示: 先启动测试服务 node Scripts/demo-server.mjs --port 27331")


if __name__ == "__main__":
    main()
