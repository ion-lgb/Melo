// 没有头部注释块的自定义源（用于测试导入失败）
const { EVENT_NAMES, send } = window.lx

send(EVENT_NAMES.inited, { status: true, sources: {} })
