/**
 * @name Melo 永不返回测试源
 * @description 仅用于测试请求超时，不打包进 App
 * @version 1.0.0
 */

const { EVENT_NAMES, on, send } = window.lx

on(EVENT_NAMES.request, () => new Promise(() => {}))

send(EVENT_NAMES.inited, {
  status: true,
  sources: {
    kw: { name: '超时源', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
  }
})
