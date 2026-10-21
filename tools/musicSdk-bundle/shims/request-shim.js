// 原版 src/renderer/utils/request.js 的 JSC 版本：
// 用 Swift（或 Node 开发脚本）注入的 __meloNative.http 替代 needle，保持响应形状
// { statusCode, statusMessage, headers, bytes, raw, body }（body 自动 JSON.parse）。
import { Buffer } from 'buffer'

const native = globalThis.__meloNative
if (!native) throw new Error('fatal: globalThis.__meloNative is missing')

const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
}
const defaultTimeout = 15000

let nextRequestId = 0
const callbacks = new Map()

function toBytes(value) {
  if (value instanceof Uint8Array) return Array.prototype.slice.call(value)
  if (Array.isArray(value)) return value.map(n => n & 0xff)
  if (typeof value === 'string') return Array.from(Buffer.from(value, 'utf8'))
  return []
}

function buildResponse(payload) {
  const raw = Buffer.from(payload.bodyBase64 || '', 'base64')
  const text = raw.toString('utf8')
  let body = text
  try { body = JSON.parse(text) } catch {}
  return {
    statusCode: payload.statusCode,
    statusMessage: payload.statusMessage,
    headers: payload.headers || {},
    bytes: payload.bytes ?? raw.length,
    raw,
    body,
  }
}

globalThis.__meloNativeHttpResponse = function (id, errorMessage, payloadJSON) {
  const callback = callbacks.get(id)
  if (!callback) return
  callbacks.delete(id)
  if (errorMessage) return callback(new Error(String(errorMessage)), null)
  try {
    callback(null, buildResponse(JSON.parse(payloadJSON)))
  } catch (error) {
    callback(error, null)
  }
}

// JSC 没有 URLSearchParams（原版 renderer 是 Chromium）；这里手写 application/x-www-form-urlencoded
function encodeForm(form) {
  const parts = []
  for (const key of Object.keys(form)) {
    const value = form[key]
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value == null ? '' : String(value))}`)
  }
  return parts.join('&')
}

function hasHeader(headers, name) {
  const target = String(name).toLowerCase()
  return Object.keys(headers).some(key => key.toLowerCase() === target)
}

function request(url, options, callback) {
  const requestId = ++nextRequestId
  const { headers = {}, timeout, method = 'get', body, form, formData } = options || {}
  const mergedHeaders = Object.assign({}, defaultHeaders, headers)
  let requestBody = body
  let formValue = form
  // 关键：body 在 JS 侧就用 JSON.stringify 固化字符串。
  // 原版 needle 也是把对象序列化后发送（QQ 音乐等接口会用收到的原始 body 校验 sign），
  // 若交给 Swift JSONSerialization 重新序列化会改变字段顺序导致签名校验失败（code 2000）。
  if (body !== undefined && body !== null && typeof body !== 'string' && !(body instanceof Uint8Array)) {
    requestBody = JSON.stringify(body)
    if (!hasHeader(mergedHeaders, 'content-type')) mergedHeaders['Content-Type'] = 'application/json'
  } else if (form && typeof form === 'object') {
    requestBody = encodeForm(form)
    if (!hasHeader(mergedHeaders, 'content-type')) mergedHeaders['Content-Type'] = 'application/x-www-form-urlencoded'
    formValue = undefined
  }
  let cancelled = false
  callbacks.set(requestId, callback)
  native.http(requestId, String(url), JSON.stringify({
    method,
    headers: mergedHeaders,
    body: requestBody,
    form: formValue,
    formData,
    timeout: typeof timeout === 'number' && timeout > 0 ? timeout : defaultTimeout,
  }))
  return {
    requestId,
    abort() {
      if (cancelled) return
      cancelled = true
      native.httpCancel(requestId)
    },
  }
}

const buildHttpPromise = (url, options = { method: 'get' }) => {
  const obj = {
    isCancelled: false,
    cancelHttp: null,
    promise: null,
  }
  obj.promise = new Promise((resolve, reject) => {
    const handle = request(url, options, (error, response) => {
      if (error) return reject(error)
      resolve(response)
    })
    obj.cancelHttp = () => {
      if (obj.isCancelled) return
      obj.isCancelled = true
      handle.abort()
    }
  })
  return obj
}

export const httpFetch = (url, options = { method: 'get' }) => {
  const requestObj = buildHttpPromise(url, options)
  requestObj.promise = requestObj.promise.catch(error => {
    if (error && error.message === 'socket hang up') {
      return Promise.reject(new Error('哦No😱...接口无法访问了！'))
    }
    switch (error && error.code) {
      case 'ETIMEDOUT':
      case 'ESOCKETTIMEDOUT':
        return Promise.reject(new Error('请求超时'))
      case 'ENOTFOUND':
        return Promise.reject(new Error('无法连接到服务器'))
      default:
        return Promise.reject(error)
    }
  })
  return requestObj
}

export const httpGet = (url, options, callback) => {
  if (typeof options === 'function') {
    callback = options
    options = {}
  }
  return buildHttpPromise(url, Object.assign({}, options, { method: 'get' })).promise
    .then(resp => callback && callback(null, resp))
    .catch(error => callback && callback(error, null))
}

export const httpPost = (url, data, options, callback) => {
  if (typeof options === 'function') {
    callback = options
    options = {}
  }
  options = Object.assign({}, options, { method: 'post', body: data })
  return buildHttpPromise(url, options).promise
    .then(resp => callback && callback(null, resp))
    .catch(error => callback && callback(error, null))
}

export const cancelHttp = requestObj => {
  if (requestObj && typeof requestObj.cancelHttp === 'function') requestObj.cancelHttp()
}

export const checkUrl = (url, options = {}) => new Promise((resolve, reject) => {
  buildHttpPromise(url, Object.assign({}, options, { method: 'head' })).promise
    .then(resp => (resp.statusCode === 200 ? resolve() : reject(new Error(resp.statusCode))))
    .catch(reject)
})

export default { httpFetch, httpGet, httpPost, cancelHttp, checkUrl }
