// 原版 `src/common/utils/tools.ts` 的 toNewMusicInfo / toOldMusicInfo 逻辑副本。
// 必须与 App 的 MeloCore.MusicInfo 模型字段保持一致，避免 JS 侧改动原版模块。

export const toNewMusicInfo = oldMusicInfo => {
  const meta = {
    songId: oldMusicInfo.songmid,
    albumName: oldMusicInfo.albumName,
    picUrl: oldMusicInfo.img,
  }
  const newInfo = {
    id: `${oldMusicInfo.source}_${oldMusicInfo.songmid}`,
    name: oldMusicInfo.name,
    singer: oldMusicInfo.singer,
    source: oldMusicInfo.source,
    interval: oldMusicInfo.interval,
    meta,
  }

  if (oldMusicInfo.source === 'local') {
    meta.filePath = oldMusicInfo.filePath ?? oldMusicInfo.songmid ?? ''
    meta.ext = oldMusicInfo.ext ?? /\.(\w+)$/.exec(meta.filePath)?.[1] ?? ''
    return newInfo
  }

  meta.qualitys = oldMusicInfo.types
  meta._qualitys = oldMusicInfo._types
  meta.albumId = oldMusicInfo.albumId
  if (meta._qualitys && meta._qualitys.flac32bit && !meta._qualitys.flac24bit) {
    meta._qualitys.flac24bit = meta._qualitys.flac32bit
    delete meta._qualitys.flac32bit
    meta.qualitys = (meta.qualitys || []).map(quality => {
      if (quality.type === 'flac32bit') quality.type = 'flac24bit'
      return quality
    })
  }

  switch (oldMusicInfo.source) {
    case 'kg':
      meta.hash = oldMusicInfo.hash
      meta.albumAudioId = oldMusicInfo.albumAudioId
      newInfo.id = oldMusicInfo.songmid + '_' + oldMusicInfo.hash
      break
    case 'tx':
      meta.strMediaMid = oldMusicInfo.strMediaMid
      meta.id = oldMusicInfo.songId
      meta.albumMid = oldMusicInfo.albumMid
      break
    case 'mg':
      meta.copyrightId = oldMusicInfo.copyrightId
      meta.lrcUrl = oldMusicInfo.lrcUrl
      meta.mrcUrl = oldMusicInfo.mrcUrl
      meta.trcUrl = oldMusicInfo.trcUrl
      break
    default:
      break
  }
  return newInfo
}

export const toOldMusicInfo = musicInfo => {
  const meta = musicInfo.meta || {}
  const oldInfo = {
    name: musicInfo.name,
    singer: musicInfo.singer,
    source: musicInfo.source,
    songmid: meta.songId,
    interval: musicInfo.interval,
    albumName: meta.albumName,
    img: meta.picUrl ?? '',
    typeUrl: {},
  }
  if (musicInfo.source === 'local') {
    oldInfo.filePath = meta.filePath
    oldInfo.ext = meta.ext
    oldInfo.albumId = ''
    oldInfo.types = []
    oldInfo._types = {}
    return oldInfo
  }
  oldInfo.albumId = meta.albumId
  oldInfo.types = meta.qualitys
  oldInfo._types = meta._qualitys

  switch (musicInfo.source) {
    case 'kg':
      oldInfo.hash = meta.hash
      oldInfo.albumAudioId = meta.albumAudioId
      break
    case 'tx':
      oldInfo.strMediaMid = meta.strMediaMid
      oldInfo.albumMid = meta.albumMid
      oldInfo.songId = meta.id
      break
    case 'mg':
      oldInfo.copyrightId = meta.copyrightId
      oldInfo.lrcUrl = meta.lrcUrl
      oldInfo.mrcUrl = meta.mrcUrl
      oldInfo.trcUrl = meta.trcUrl
      break
    default:
      break
  }
  return oldInfo
}

export const dedupeMusicList = list => {
  const ids = new Set()
  return list.filter(item => {
    if (!item || !item.id || ids.has(item.id)) return false
    ids.add(item.id)
    return true
  })
}
