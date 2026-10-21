// `@renderer/store` stub：内置元数据源不需要 userApi/apis（取链由 JSCustomSourceService 负责）。
export const apiSource = { value: 'builtin' }
export const userApi = { apis: {} }
export const proxy = { enable: false, host: '', port: '', envProxy: null }
export default { apiSource, userApi, proxy }
