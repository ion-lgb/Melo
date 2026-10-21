// Node `zlib` 的 JSC shim：用 pako 纯 JS 实现（无需 native zlib），
// 兼容 Node 的 callback API：inflate(data[, options], cb)、deflate、deflateRaw、inflateRaw。
import pako from 'pako'
import { Buffer } from 'buffer'

const toBytes = value => {
  if (value instanceof Uint8Array) return value
  if (Array.isArray(value)) return Uint8Array.from(value.map(n => n & 0xff))
  if (typeof value === 'string') return Uint8Array.from(Buffer.from(value, 'binary'))
  return new Uint8Array(0)
}

const concatChunks = chunks => {
  const arrays = chunks.filter(Boolean).map(chunk => (chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk)))
  const total = arrays.reduce((sum, array) => sum + array.length, 0)
  const output = new Uint8Array(total)
  let offset = 0
  for (const array of arrays) {
    output.set(array, offset)
    offset += array.length
  }
  return output
}

// 容忍不完整 zlib 流（对应 Node 的 finishFlush: Z_SYNC_FLUSH 行为，tx/qrcDecode 用到）
const tolerantInflate = input => {
  const inflater = new pako.Inflate({ chunkSize: 65536 })
  try {
    inflater.push(input, false)
  } catch {
    // 忽略尾部错误，尽量返回已解压内容
  }
  return concatChunks(inflater.chunks || [])
}

const inflateSync = (data, options) => {
  const input = toBytes(data)
  try {
    return pako.inflate(input)
  } catch (error) {
    if (options && options.finishFlush === 2) {
      return tolerantInflate(input)
    }
    throw error
  }
}

const deflateSync = (data, options, raw) => {
  const input = toBytes(data)
  return raw ? pako.deflateRaw(input, options) : pako.deflate(input, options)
}

const asyncify = (syncFn, raw) => (data, options, callback) => {
  if (typeof options === 'function') {
    callback = options
    options = {}
  }
  Promise.resolve().then(() => {
    try {
      callback(null, Buffer.from(syncFn(data, options, raw)))
    } catch (error) {
      callback(error, null)
    }
  })
}

export const inflate = asyncify(inflateSync, false)
export const deflate = asyncify(deflateSync, false)
export const inflateRaw = asyncify(inflateSync, true)
export const deflateRaw = asyncify(deflateSync, true)

export const constants = {
  Z_NO_FLUSH: 0,
  Z_SYNC_FLUSH: 2,
  Z_FULL_FLUSH: 3,
  Z_FINISH: 4,
  Z_OK: 0,
  Z_BUF_ERROR: -5,
}

export default { inflate, deflate, inflateRaw, deflateRaw, constants }
