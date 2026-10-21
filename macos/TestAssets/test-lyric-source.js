/**
 * @name Melo 歌词测试源
 * @description 仅用于 MeloJSTests 的本地歌词源，不打包进 App
 * @version 1.0.0
 * @author Melo Tests
 */

const { EVENT_NAMES, on, send } = window.lx

on(EVENT_NAMES.request, ({ action }) => {
  if (action === 'lyric') {
    return Promise.resolve({
      lyric: '[00:00.00]Melo test lyric',
      tlyric: '[00:00.00]Melo test translated lyric'
    })
  }
  return Promise.reject(new Error('unsupported action: ' + action))
})

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    local: { name: 'Melo 歌词测试源', type: 'music', actions: ['lyric'], qualitys: [] }
  }
})
