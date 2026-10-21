/**
 * @name Melo 无 inited 测试源
 * @description 仅用于测试激活超时，不发送 inited 事件，不打包进 App
 * @version 1.0.0
 */

const { EVENT_NAMES, on } = window.lx

on(EVENT_NAMES.request, () => Promise.reject(new Error('no inited')))
