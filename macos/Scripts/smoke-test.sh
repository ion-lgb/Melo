#!/usr/bin/env bash
# 端到端冒烟测试：本地 demo server + 生成的测试数据 + MeloSmoke（无 GUI）
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-27331}"
DATA="${DATA:-/tmp/melo-smoke-data}"
SCRATCH="${SCRATCH:-/tmp/melo-smoke-build}"

echo "==> 启动测试服务 (port $PORT)"
node Scripts/demo-server.mjs --port "$PORT" > /tmp/melo-smoke-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  grep -q "READY" /tmp/melo-smoke-server.log 2>/dev/null && break
  sleep 0.1
done
grep -q "READY" /tmp/melo-smoke-server.log || { echo "测试服务启动失败"; cat /tmp/melo-smoke-server.log; exit 1; }
echo "    server ready"

echo "==> 生成测试数据 -> $DATA"
python3 Scripts/make-test-data.py "$DATA" > /dev/null

echo "==> 运行 MeloSmoke"
swift run --scratch-path "$SCRATCH" MeloSmoke \
  --data-dir "$DATA" \
  --source TestAssets/demo-source.js \
  --music-file TestAssets/sample-music-info.json \
  --index 0 \
  --server "http://127.0.0.1:$PORT/health"

echo "==> 冒烟测试通过"
