// 测试桩 bundle：用于离线验证 JSMetadataService 的 JSON 解析 / 错误 / 超时路径。
// 结构与真实 musicSdk.bundle.js 暴露的 MeloMetadata + __meloCall 胶水保持一致。
const pending = {}
globalThis.__meloPending = pending

const safeJSON = value => JSON.stringify(value === undefined ? null : value)
globalThis.__meloTrack = (tag, value) => {
  pending[tag] = { state: 'pending' }
  Promise.resolve(value).then(
    result => { pending[tag] = { state: 'resolved', json: safeJSON(result) } },
    error => { pending[tag] = { state: 'rejected', message: String((error && error.message) || error) } }
  )
}

function music(id) {
  return {
    id,
    name: 'Stub 歌曲',
    singer: 'Stub 歌手',
    source: 'stub',
    interval: '00:10',
    meta: {
      songId: id.split('_').pop(),
      albumName: 'Stub 专辑',
      picUrl: null,
      qualitys: [{ type: '128k', size: null }],
      _qualitys: { '128k': { size: null } },
    },
  }
}

const sources = [{ id: 'stub', name: 'Stub 源' }]

globalThis.MeloMetadata = {
  apiVersion: 'test',
  sources,
  prepare() { return Promise.resolve({ ok: true, sources }) },
  hotSearch(source) {
    if (source === 'throw') throw new Error('stub failure')
    if (source === 'never') return new Promise(() => {})
    return Promise.resolve(['stub-hot-1', 'stub-hot-2', source])
  },
  searchMusic() {
    return Promise.resolve({ list: [music('stub_1')], total: 1, page: 1, limit: 30, allPage: 1, source: 'stub' })
  },
  searchSongList() {
    return Promise.resolve({
      list: [{ id: 'sl_1', name: 'Stub 歌单', source: 'stub', cover: null, creator: 'Stub 作者', description: null, playCount: '100', total: 2 }],
      total: 1, page: 1, limit: 20, allPage: 1, source: 'stub',
    })
  },
  leaderboards() {
    return Promise.resolve([{ id: 'stub__1', name: 'Stub 榜', source: 'stub', imgUrl: null, total: null }])
  },
  leaderboardMusics() {
    return Promise.resolve({ list: [music('stub_2')], total: 1, page: 1, limit: 100, allPage: 1, source: 'stub' })
  },
  songListSorts() { return Promise.resolve([{ id: 'new', name: '最新' }]) },
  songListTags() {
    return Promise.resolve({
      groups: [{ name: 'Stub 分类', tags: [{ id: 'tag1', name: '标签 1', source: 'stub' }] }],
      hot: [{ id: 'hot1', name: '热门标签', source: 'stub' }],
    })
  },
  songLists() {
    return Promise.resolve({
      list: [{ id: 'sl_2', name: 'Stub 歌单 2', source: 'stub', cover: null, creator: null, description: null, playCount: null, total: null }],
      total: 1, page: 1, limit: 20, allPage: 1, source: 'stub',
    })
  },
  songListDetail() {
    return Promise.resolve({
      info: { id: 'sl_3', name: 'Stub 歌单详情', source: 'stub', cover: null, creator: null, description: null, playCount: null, total: 1 },
      page: { list: [music('stub_3')], total: 1, page: 1, limit: 200, allPage: 1, source: 'stub' },
    })
  },
  lyric() {
    return Promise.resolve({ lyric: '[00:00.00]stub lyric', tlyric: null, rlyric: null, lxlyric: '[00:00.00]<0,10>stub' })
  },
  comments({ source, page = 1, limit = 20 } = {}) {
    if (source === 'throw') throw new Error('获取评论失败')
    if (source === 'unsupported') throw new Error('Stub 源不支持评论')
    if (source === 'never') return new Promise(() => {})
    return Promise.resolve({
      source,
      comments: [
        {
          id: 1001,
          text: '第一条评论',
          time: 1700000000,
          timeStr: '2023-11-15 06:13',
          location: '广东',
          userName: '用户A',
          avatar: 'https://example.com/a.jpg',
          userId: 42,
          likedCount: '7',
          reply: {
            id: 'r1', text: '回复内容', userName: '用户B', avatar: null,
            userId: '88', likedCount: 2, location: '北京',
          },
        },
        {
          id: '1002',
          text: '第二条评论',
          time: null,
          timeStr: null,
          userName: '用户C',
          likedCount: 0,
          reply: [],
        },
      ],
      total: 2,
      page,
      limit,
      maxPage: 1,
    })
  },
  hotComments({ source, limit = 100 } = {}) {
    if (source === 'throw') throw new Error('获取热门评论失败')
    if (source === 'unsupported') throw new Error('Stub 源不支持热门评论')
    if (source === 'never') return new Promise(() => {})
    return Promise.resolve({
      source,
      comments: [
        {
          id: 'h1', text: '热门评论', time: 1700000000, userName: '用户H',
          avatar: 'https://example.com/h.jpg', userId: '99', likedCount: 99,
          reply: [{ id: 'hr', text: '热门回复', userName: '用户I', likedCount: 3 }],
        },
      ],
      total: 1,
      page: 1,
      limit,
      maxPage: 1,
    })
  },
  throwError() { throw new Error('stub failure') },
  neverResolve() { return new Promise(() => {}) },
  nullResult() { return Promise.resolve(null) },
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
