// MeloJS 内置元数据源入口：把原版 musicSdk 的 kw/kg/tx/wy/mg 元数据模块
// 组装成 `globalThis.MeloMetadata`，供 Swift `JSMetadataService` 调用。
//
// 注意：
// - 不 import 各源 index.js（会拉入 api-source / userApi / 取链逻辑）；
// - 所有 MusicInfo 经原版 toNewMusicInfo 转换；
// - 单源失败在聚合路径（source='all'）中被隔离为空结果。
import './shims/globals.js'
import { toNewMusicInfo, toOldMusicInfo, dedupeMusicList } from './shims/music-info.js'

// —— kw / 酷我
import kwMusicSearch from '../../../src/renderer/utils/musicSdk/kw/musicSearch.js'
import kwLeaderboard from '../../../src/renderer/utils/musicSdk/kw/leaderboard.js'
import kwSongList from '../../../src/renderer/utils/musicSdk/kw/songList.js'
import kwHotSearch from '../../../src/renderer/utils/musicSdk/kw/hotSearch.js'
import kwLyric from '../../../src/renderer/utils/musicSdk/kw/lyric.js'
import kwPic from '../../../src/renderer/utils/musicSdk/kw/pic.js'
import kwComment from '../../../src/renderer/utils/musicSdk/kw/comment.js'

// —— kg / 酷狗
import kgMusicSearch from '../../../src/renderer/utils/musicSdk/kg/musicSearch.js'
import kgLeaderboard from '../../../src/renderer/utils/musicSdk/kg/leaderboard.js'
import kgSongList from '../../../src/renderer/utils/musicSdk/kg/songList.js'
import kgHotSearch from '../../../src/renderer/utils/musicSdk/kg/hotSearch.js'
import kgLyric from '../../../src/renderer/utils/musicSdk/kg/lyric.js'
import kgPic from '../../../src/renderer/utils/musicSdk/kg/pic.js'
import kgComment from '../../../src/renderer/utils/musicSdk/kg/comment.js'

// —— tx / QQ 音乐
import txMusicSearch from '../../../src/renderer/utils/musicSdk/tx/musicSearch.js'
import txLeaderboard from '../../../src/renderer/utils/musicSdk/tx/leaderboard.js'
import txSongList from '../../../src/renderer/utils/musicSdk/tx/songList.js'
import txHotSearch from '../../../src/renderer/utils/musicSdk/tx/hotSearch.js'
import txLyric from '../../../src/renderer/utils/musicSdk/tx/lyric.js'
import txComment from '../../../src/renderer/utils/musicSdk/tx/comment.js'

// —— wy / 网易云音乐
import wyMusicSearch from '../../../src/renderer/utils/musicSdk/wy/musicSearch.js'
import wyLeaderboard from '../../../src/renderer/utils/musicSdk/wy/leaderboard.js'
import wySongList from '../../../src/renderer/utils/musicSdk/wy/songList.js'
import wyHotSearch from '../../../src/renderer/utils/musicSdk/wy/hotSearch.js'
import wyLyric from '../../../src/renderer/utils/musicSdk/wy/lyric.js'
import wyComment from '../../../src/renderer/utils/musicSdk/wy/comment.js'

// —— mg / 咪咕音乐
import mgMusicSearch from '../../../src/renderer/utils/musicSdk/mg/musicSearch.js'
import mgLeaderboard from '../../../src/renderer/utils/musicSdk/mg/leaderboard.js'
import mgSongList from '../../../src/renderer/utils/musicSdk/mg/songList.js'
import mgHotSearch from '../../../src/renderer/utils/musicSdk/mg/hotSearch.js'
import mgLyric from '../../../src/renderer/utils/musicSdk/mg/lyric.js'
import mgPic from '../../../src/renderer/utils/musicSdk/mg/pic.js'
import mgComment from '../../../src/renderer/utils/musicSdk/mg/comment.js'

const modules = {
  kw: { musicSearch: kwMusicSearch, leaderboard: kwLeaderboard, songList: kwSongList, hotSearch: kwHotSearch, lyric: kwLyric, pic: kwPic, comment: kwComment },
  kg: { musicSearch: kgMusicSearch, leaderboard: kgLeaderboard, songList: kgSongList, hotSearch: kgHotSearch, lyric: kgLyric, pic: kgPic, comment: kgComment },
  tx: { musicSearch: txMusicSearch, leaderboard: txLeaderboard, songList: txSongList, hotSearch: txHotSearch, lyric: txLyric, comment: txComment },
  wy: { musicSearch: wyMusicSearch, leaderboard: wyLeaderboard, songList: wySongList, hotSearch: wyHotSearch, lyric: wyLyric, comment: wyComment },
  mg: { musicSearch: mgMusicSearch, leaderboard: mgLeaderboard, songList: mgSongList, hotSearch: mgHotSearch, lyric: mgLyric, pic: mgPic, comment: mgComment },
}

const sources = [
  { id: 'kw', name: '酷我音乐' },
  { id: 'kg', name: '酷狗音乐' },
  { id: 'tx', name: 'QQ音乐' },
  { id: 'wy', name: '网易云音乐' },
  { id: 'mg', name: '咪咕音乐' },
]
const sourceIds = sources.map(source => source.id)

const sourceName = source => sources.find(item => item.id === source)?.name ?? source

function warn(source, error) {
  try {
    console.warn(`[metadata][${source}] ${(error && error.message) || error}`)
  } catch {}
}

function requireModules(source) {
  const mod = modules[source]
  if (!mod) throw new Error(`未知音源: ${source}`)
  return mod
}

function clampPage(page) {
  return Math.max(1, Math.floor(Number(page) || 1))
}
function clampLimit(limit, fallback = 20) {
  return Math.max(1, Math.floor(Number(limit) || fallback))
}
function allPageOf(total, limit) {
  return limit > 0 ? Math.ceil(total / limit) : 0
}

function mapMusicList(rawList) {
  return dedupeMusicList((rawList || []).filter(Boolean).map(toNewMusicInfo))
}

function mapSongListItems(rawList, source) {
  return (rawList || []).filter(item => item && item.id != null).map(item => ({
    id: String(item.id),
    name: item.name || '',
    source,
    cover: item.img ?? null,
    creator: item.author ?? null,
    description: item.desc ?? null,
    playCount: item.play_count != null ? String(item.play_count) : null,
    total: item.total != null ? Number(item.total) : null,
    raw: item,
  }))
}

function tagOf(item, source) {
  return { id: String(item.id), name: String(item.name ?? ''), source: item.source || source }
}

// 源分页与 App 请求的 limit 可能不同（各源自带 limit：kw 100、tx 300、wy 100000...）。
// 该 helper 拉取覆盖请求范围所需的所有源分页，再按 App 的 page/limit 切片。
async function paginate(fetchPage, page, limit) {
  const requestedPage = clampPage(page)
  const requestedLimit = clampLimit(limit)
  const start = (requestedPage - 1) * requestedLimit
  const end = start + requestedLimit

  const first = await fetchPage(1)
  let all = (first && first.list ? first.list.slice() : [])
  let total = Number(first && first.total) || all.length
  let sourcePage = 1
  while (all.length < end && all.length < total && sourcePage < 200) {
    sourcePage++
    let result
    try {
      result = await fetchPage(sourcePage)
    } catch {
      break
    }
    if (!result || !result.list || !result.list.length) break
    all = all.concat(result.list)
    total = Number(result.total) || total
  }
  const rawList = all.slice(start, end)
  return {
    rawList,
    total,
    first,
    page: requestedPage,
    limit: requestedLimit,
    allPage: allPageOf(total, requestedLimit),
  }
}

// ---------------------------------------------------------------- 单曲搜索

async function searchMusicOne(source, { keyword, page, limit }) {
  const mod = requireModules(source)
  const requestedPage = clampPage(page)
  const requestedLimit = clampLimit(limit, 30)
  const result = await mod.musicSearch.search(keyword, requestedPage, requestedLimit)
  const list = mapMusicList(result && result.list)
  const total = Number(result && result.total) || 0
  return {
    list,
    total,
    page: requestedPage,
    limit: requestedLimit,
    allPage: allPageOf(total, requestedLimit),
    source,
  }
}

async function searchMusic({ keyword, source = 'all', page = 1, limit = 30 } = {}) {
  const text = String(keyword == null ? '' : keyword).trim()
  if (!text) return { list: [], total: 0, page: clampPage(page), limit: clampLimit(limit, 30), allPage: 0, source }
  if (source !== 'all') return searchMusicOne(source, { keyword: text, page, limit })

  const results = await Promise.all(sourceIds.map(id =>
    searchMusicOne(id, { keyword: text, page, limit }).catch(error => {
      warn(id, error)
      return { list: [], total: 0, page: clampPage(page), limit: clampLimit(limit, 30), allPage: 0, source: id }
    })))
  const list = dedupeMusicList(results.flatMap(result => result.list))
  const total = Math.max(0, ...results.map(result => result.total))
  return {
    list,
    total,
    page: clampPage(page),
    limit: clampLimit(limit, 30),
    allPage: allPageOf(total, clampLimit(limit, 30)),
    source: 'all',
  }
}

// ---------------------------------------------------------------- 热搜 / 排行榜

async function hotSearch(source) {
  const mod = requireModules(source)
  if (!mod.hotSearch || typeof mod.hotSearch.getList !== 'function') {
    throw new Error(`${sourceName(source)}不支持热搜`)
  }
  const result = await mod.hotSearch.getList()
  return (result && result.list) || []
}

async function leaderboards(source) {
  const mod = requireModules(source)
  const result = await mod.leaderboard.getBoards()
  const list = (result && result.list) || []
  return list.map(board => ({
    id: String(board.id),
    name: String(board.name ?? ''),
    source: board.source || source,
    imgUrl: board.imgUrl ?? board.img ?? null,
    total: board.total != null ? Number(board.total) : null,
  }))
}

function splitBoardId(boardId) {
  const text = String(boardId == null ? '' : boardId)
  const index = text.indexOf('__')
  if (index <= 0) throw new Error(`无效的排行榜 id: ${text}`)
  return { source: text.slice(0, index), bangId: text.slice(index + 2) }
}

async function leaderboardMusics({ boardId, page = 1, limit = 100 } = {}) {
  const { source, bangId } = splitBoardId(boardId)
  const mod = requireModules(source)
  const result = await paginate(pageNumber => mod.leaderboard.getList(bangId, pageNumber), page, limit)
  return {
    list: mapMusicList(result.rawList),
    total: result.total,
    page: result.page,
    limit: result.limit,
    allPage: result.allPage,
    source,
  }
}

// ---------------------------------------------------------------- 歌单广场

async function songListSorts(source) {
  const mod = requireModules(source)
  return (mod.songList.sortList || []).map(sort => ({ id: String(sort.id), name: String(sort.name ?? '') }))
}

async function songListTags(source) {
  const mod = requireModules(source)
  const raw = await mod.songList.getTags()
  const groups = ((raw && raw.tags) || []).map(group => ({
    name: group.name || '',
    tags: (group.list || []).map(tag => tagOf(tag, source)),
  }))
  const hot = ((raw && raw.hotTag) || []).map(tag => tagOf(tag, source))
  return { groups, hot }
}

async function songLists({ source, tagId = '', sortId = '', page = 1, limit = 20 } = {}) {
  const mod = requireModules(source)
  const result = await paginate(
    pageNumber => mod.songList.getList(sortId, tagId, pageNumber),
    page,
    limit
  )
  return {
    list: mapSongListItems(result.rawList, source),
    total: result.total,
    page: result.page,
    limit: result.limit,
    allPage: result.allPage,
    source,
  }
}

function detailInfoOf(rawInfo, source, id, total) {
  const info = rawInfo || {}
  return {
    id: String(id),
    name: info.name || '',
    source,
    cover: info.img ?? null,
    creator: info.author ?? null,
    description: info.desc ?? null,
    playCount: info.play_count != null ? String(info.play_count) : null,
    total: total != null ? Number(total) : null,
    raw: info,
  }
}

async function songListDetail({ id, source, page = 1, limit = 200 } = {}) {
  const mod = requireModules(source)
  const result = await paginate(
    pageNumber => mod.songList.getListDetail(id, pageNumber),
    page,
    limit
  )
  const first = result.first || {}
  return {
    info: detailInfoOf(first.info, source, id, result.total),
    page: {
      list: mapMusicList(result.rawList),
      total: result.total,
      page: result.page,
      limit: result.limit,
      allPage: result.allPage,
      source,
    },
  }
}

async function searchSongListOne(source, { keyword, page, limit }) {
  const mod = requireModules(source)
  const requestedPage = clampPage(page)
  const requestedLimit = clampLimit(limit, 20)
  const result = await mod.songList.search(keyword, requestedPage, requestedLimit)
  const total = Number(result && result.total) || 0
  return {
    list: mapSongListItems(result && result.list, source),
    total,
    page: requestedPage,
    limit: requestedLimit,
    allPage: allPageOf(total, requestedLimit),
    source,
  }
}

async function searchSongList({ keyword, source = 'all', page = 1, limit = 20 } = {}) {
  const text = String(keyword == null ? '' : keyword).trim()
  if (!text) return { list: [], total: 0, page: clampPage(page), limit: clampLimit(limit, 20), allPage: 0, source }
  if (source !== 'all') return searchSongListOne(source, { keyword: text, page, limit })

  const results = await Promise.all(sourceIds.map(id =>
    searchSongListOne(id, { keyword: text, page, limit }).catch(error => {
      warn(id, error)
      return { list: [], total: 0, page: clampPage(page), limit: clampLimit(limit, 20), allPage: 0, source: id }
    })))
  const lists = results.flatMap(result => result.list)
  const seen = new Set()
  const list = lists.filter(item => {
    const key = `${item.source}_${item.id}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
  const total = Math.max(0, ...results.map(result => result.total))
  return {
    list,
    total,
    page: clampPage(page),
    limit: clampLimit(limit, 20),
    allPage: allPageOf(total, clampLimit(limit, 20)),
    source: 'all',
  }
}

// ---------------------------------------------------------------- 歌词

async function lyric({ source, musicInfo } = {}) {
  const mod = requireModules(source)
  const oldInfo = toOldMusicInfo(musicInfo || { meta: {} })
  let requestObj
  if (typeof mod.lyric === 'function') {
    requestObj = mod.lyric(oldInfo.songmid)
  } else if (mod.lyric && typeof mod.lyric.getLyric === 'function') {
    requestObj = mod.lyric.getLyric(oldInfo)
  } else {
    throw new Error(`${sourceName(source)}不支持歌词`)
  }
  const promise = requestObj && requestObj.promise ? requestObj.promise : requestObj
  const info = await promise
  if (!info || !info.lyric) return null
  return {
    lyric: info.lyric || '',
    tlyric: info.tlyric || null,
    rlyric: info.rlyric || null,
    lxlyric: info.lxlyric || null,
  }
}

// ---------------------------------------------------------------- 歌曲评论

function normalizeCommentReply(item) {
  if (!item) return null
  return {
    id: item.id == null ? '' : String(item.id),
    text: item.text == null ? '' : String(item.text),
    userName: item.userName == null ? '' : String(item.userName),
    avatar: item.avatar == null || item.avatar === '' ? null : String(item.avatar),
    userId: item.userId == null || item.userId === '' ? null : String(item.userId),
    likedCount: item.likedCount == null ? null : Number(item.likedCount),
    location: item.location == null || item.location === '' ? null : String(item.location),
  }
}

function normalizeComment(item) {
  if (!item) return null
  const replies = Array.isArray(item.reply) ? item.reply : (item.reply ? [item.reply] : [])
  return {
    id: item.id == null ? '' : String(item.id),
    text: item.text == null ? '' : String(item.text),
    time: item.time == null || item.time === '' ? null : Number(item.time),
    timeStr: item.timeStr == null || item.timeStr === '' ? null : String(item.timeStr),
    location: item.location == null || item.location === '' ? null : String(item.location),
    userName: item.userName == null ? '' : String(item.userName),
    avatar: item.avatar == null || item.avatar === '' ? null : String(item.avatar),
    userId: item.userId == null || item.userId === '' ? null : String(item.userId),
    likedCount: item.likedCount == null ? 0 : Number(item.likedCount),
    reply: normalizeCommentReply(replies[0]),
  }
}

function normalizeCommentPage(source, result, page, limit) {
  const rawComments = result && Array.isArray(result.comments) ? result.comments : []
  const comments = rawComments.map(normalizeComment).filter(Boolean)
  const total = Number(result && result.total)
  const safeTotal = Number.isFinite(total) ? total : comments.length
  const safeLimit = Math.max(1, Number(limit) || 20)
  return {
    source: String((result && result.source) || source),
    comments,
    total: safeTotal,
    page: Number((result && result.page) || page) || page,
    limit: Number((result && result.limit) || safeLimit) || safeLimit,
    maxPage: Number((result && result.maxPage) || Math.ceil(safeTotal / safeLimit) || 1),
  }
}

async function comments({ source, musicInfo, page = 1, limit = 20 } = {}) {
  const mod = requireModules(source)
  if (!mod.comment || typeof mod.comment.getComment !== 'function') {
    throw new Error(`${sourceName(source)}不支持评论`)
  }
  const requestedPage = clampPage(page)
  const requestedLimit = clampLimit(limit)
  const oldInfo = toOldMusicInfo(musicInfo || { meta: {} })
  const result = await mod.comment.getComment(oldInfo, requestedPage, requestedLimit)
  return normalizeCommentPage(source, result, requestedPage, requestedLimit)
}

async function hotComments({ source, musicInfo, limit = 100 } = {}) {
  const mod = requireModules(source)
  if (!mod.comment || typeof mod.comment.getHotComment !== 'function') {
    throw new Error(`${sourceName(source)}不支持热门评论`)
  }
  const requestedLimit = clampLimit(limit, 100)
  const oldInfo = toOldMusicInfo(musicInfo || { meta: {} })
  const result = await mod.comment.getHotComment(oldInfo, 1, requestedLimit)
  return normalizeCommentPage(source, result, 1, requestedLimit)
}

// ---------------------------------------------------------------- 生命周期

async function prepare() {
  // 无网络初始化：仅确认模块已加载并返回源列表
  const availability = {}
  for (const id of sourceIds) {
    const mod = modules[id]
    availability[id] = {
      musicSearch: !!mod.musicSearch,
      leaderboard: !!mod.leaderboard,
      songList: !!mod.songList,
      hotSearch: !!mod.hotSearch,
      lyric: !!mod.lyric,
      comment: !!(mod.comment && typeof mod.comment.getComment === 'function'),
    }
  }
  console.log('[musicSdk] prepared:', JSON.stringify(availability))
  return { ok: true, sources }
}

globalThis.MeloMetadata = {
  apiVersion: '1.0.0',
  sources,
  prepare,
  hotSearch,
  searchMusic,
  searchSongList,
  leaderboards,
  leaderboardMusics,
  songListSorts,
  songListTags,
  songLists,
  songListDetail,
  lyric,
  comments,
  hotComments,
}

// ---------------------------------------------------------------- Swift 调用胶水
// Swift 通过 evaluateScript("__meloCall(tag, method, argsJSON)") 调用；
// 结果写入 __meloPending[tag] 供 Swift 轮询，避免直接桥接 Promise。
const pending = {}
globalThis.__meloPending = pending

function safeJSON(value) {
  try {
    return JSON.stringify(value === undefined ? null : value)
  } catch {
    return JSON.stringify(String(value))
  }
}

globalThis.__meloTrack = function (tag, value) {
  pending[tag] = { state: 'pending' }
  Promise.resolve(value).then(result => {
    pending[tag] = { state: 'resolved', json: safeJSON(result) }
  }, error => {
    pending[tag] = { state: 'rejected', message: String((error && error.message) || error) }
  })
}

globalThis.__meloCall = function (tag, method, argsJSON) {
  let args
  try {
    args = argsJSON ? JSON.parse(argsJSON) : []
  } catch (error) {
    pending[tag] = { state: 'rejected', message: `参数解析失败: ${error.message}` }
    return
  }
  const fn = globalThis.MeloMetadata[method]
  if (typeof fn !== 'function') {
    pending[tag] = { state: 'rejected', message: `MeloMetadata 不支持方法: ${method}` }
    return
  }
  let value
  try {
    value = fn.apply(null, args)
  } catch (error) {
    pending[tag] = { state: 'rejected', message: String((error && error.message) || error) }
    return
  }
  globalThis.__meloTrack(tag, value)
}
