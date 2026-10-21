// `dns` stub：musicSdk 里 dnsLookup 仅被 api-test/api-temp 使用，生产路径不需要。
export const lookup = (hostname, options, callback) => {
  if (typeof options === 'function') callback = options
  const error = new Error('dns.lookup is not supported in MeloJS')
  if (callback) callback(error)
  else throw error
}
export default { lookup }
