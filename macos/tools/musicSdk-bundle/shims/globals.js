// 全局环境 shim：必须在所有源模块之前执行（entry.js 的第一个 import）。
// 由 Swift JSMetadataRuntime（或 Node 开发脚本）预先注入 globalThis.__meloNative。
import { Buffer } from 'buffer'

const native = globalThis.__meloNative
if (!native) throw new Error('fatal: globalThis.__meloNative is missing')

globalThis.Buffer = Buffer
globalThis.window = globalThis
globalThis.self = globalThis
globalThis.global = globalThis

if (typeof globalThis.navigator === 'undefined') {
  globalThis.navigator = {
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Melo/2.12.6',
    platform: 'MacIntel',
    language: 'zh-CN',
  }
}
if (typeof globalThis.document === 'undefined') {
  const fakeElement = () => ({
    setAttribute() {},
    style: {},
    appendChild() {},
    removeChild() {},
    parentNode: null,
  })
  globalThis.document = {
    createElement: fakeElement,
    body: { appendChild() {}, removeChild() {} },
    getElementById() { return null },
    addEventListener() {},
    removeEventListener() {},
  }
}
if (typeof globalThis.process === 'undefined') {
  globalThis.process = {
    platform: 'darwin',
    versions: { app: '2.12.6' },
    env: {},
  }
}
if (typeof globalThis.location === 'undefined') {
  globalThis.location = { href: 'about:blank', protocol: 'about:', host: '' }
}
if (typeof globalThis.performance === 'undefined') {
  globalThis.performance = { now: () => Date.now() }
}

const stringifyArg = arg => {
  if (typeof arg === 'string') return arg
  if (arg instanceof Error) return arg.stack || `${arg.name}: ${arg.message}`
  if (typeof arg === 'undefined') return 'undefined'
  try {
    const text = JSON.stringify(arg)
    return text === undefined ? String(arg) : text
  } catch {
    return String(arg)
  }
}
const makeLog = level => (...args) => {
  native.log(level, args.map(stringifyArg).join(' '))
}
globalThis.console = {
  log: makeLog('log'),
  info: makeLog('info'),
  warn: makeLog('warn'),
  error: makeLog('error'),
  debug: makeLog('debug'),
  trace: makeLog('trace'),
}


// URLSearchParams / URL / TextEncoder / TextDecoder（JavaScriptCore 缺失，wy 等源会用到）
if (typeof globalThis.URLSearchParams === 'undefined') {
  class URLSearchParamsPolyfill {
    constructor(init = '') {
      this._entries = []
      if (typeof init === 'string') {
        const text = init.startsWith('?') ? init.slice(1) : init
        if (text) {
          for (const part of text.split('&')) {
            if (!part) continue
            const index = part.indexOf('=')
            const key = index < 0 ? part : part.slice(0, index)
            const value = index < 0 ? '' : part.slice(index + 1)
            this.append(decodeURIComponent(key.replace(/\+/g, ' ')), decodeURIComponent(value.replace(/\+/g, ' ')))
          }
        }
      } else if (Array.isArray(init) || init instanceof Map) {
        for (const [key, value] of init) this.append(key, value)
      } else if (init && typeof init === 'object') {
        for (const key of Object.keys(init)) this.append(key, init[key])
      }
    }
    append(key, value) { this._entries.push([String(key), String(value)]) }
    set(key, value) {
      const target = String(key)
      const index = this._entries.findIndex(([k]) => k === target)
      const entry = [target, String(value)]
      if (index >= 0) this._entries[index] = entry
      else this._entries.push(entry)
    }
    get(key) { const entry = this._entries.find(([k]) => k === String(key)); return entry ? entry[1] : null }
    getAll(key) { return this._entries.filter(([k]) => k === String(key)).map(([, v]) => v) }
    has(key) { return this._entries.some(([k]) => k === String(key)) }
    delete(key) { this._entries = this._entries.filter(([k]) => k !== String(key)) }
    forEach(callback, thisArg) { for (const [key, value] of this._entries) callback.call(thisArg, value, key, this) }
    entries() { return this._entries[Symbol.iterator]() }
    keys() { return this._entries.map(([k]) => k)[Symbol.iterator]() }
    values() { return this._entries.map(([, v]) => v)[Symbol.iterator]() }
    [Symbol.iterator]() { return this.entries() }
    toString() { return this._entries.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&') }
  }
  globalThis.URLSearchParams = URLSearchParamsPolyfill
}
if (typeof globalThis.TextEncoder === 'undefined') {
  globalThis.TextEncoder = class TextEncoder {
    encode(text = '') { return new Uint8Array(Buffer.from(String(text), 'utf8')) }
  }
}
if (typeof globalThis.TextDecoder === 'undefined') {
  globalThis.TextDecoder = class TextDecoder {
    constructor(encoding = 'utf-8') { this.encoding = String(encoding).toLowerCase() }
    decode(bytes) {
      if (!bytes) return ''
      const buffer = Buffer.from(bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : bytes)
      if (this.encoding === 'gbk' || this.encoding === 'gb18030' || this.encoding === 'big5') {
        try { return buffer.toString('binary') } catch { return '' }
      }
      return buffer.toString('utf8')
    }
  }
}
if (typeof globalThis.URL === 'undefined') {
  globalThis.URL = class URLPolyfill {
    constructor(input, base) {
      const text = String(input)
      const absolute = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)
      const full = absolute ? text : new URLSearchParamsPolyfill()
      if (!absolute) { this.href = text; this.protocol = ''; this.host = ''; this.hostname = ''; this.pathname = text; this.search = ''; this.hash = ''; return }
      this.href = text
      const match = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(text)
      if (match) {
        this.protocol = match[1]
        this.host = match[2]
        this.hostname = match[2].split(':')[0]
        this.pathname = match[3] || '/'
        this.search = match[4] || ''
        this.hash = match[5] || ''
      } else {
        this.protocol = text.slice(0, text.indexOf(':') + 1)
        this.host = ''; this.hostname = ''; this.pathname = text; this.search = ''; this.hash = ''
      }
      const q = this.search.startsWith('?') ? this.search.slice(1) : this.search
      this.searchParams = new URLSearchParamsPolyfill(q)
    }
    toString() { return this.href }
  }
}

// 定时器：源模块基本不用，但运行时兜底（Swift 侧提供 native.timerStart）
let nextTimerId = 0
const activeTimers = {}
if (typeof native.timerStart === 'function') {
  for (const [name, repeat] of [['setTimeout', false], ['setInterval', true]]) {
    globalThis[name] = function (fn, delay = 0, ...args) {
      const id = ++nextTimerId
      activeTimers[id] = true
      native.timerStart(id, () => {
        if (!activeTimers[id]) return
        try {
          if (typeof fn === 'function') fn(...args)
          else (0, eval)(String(fn))
        } catch (error) {
          console.error('timer error:', error)
        }
        if (!repeat) delete activeTimers[id]
      }, Number(delay) || 0, repeat)
      return id
    }
  }
  globalThis.clearTimeout = globalThis.clearInterval = id => {
    delete activeTimers[id]
    native.timerCancel(id)
  }
} else {
  globalThis.setTimeout = (fn, _delay, ...args) => Promise.resolve().then(() => fn(...args))
  globalThis.setInterval = () => 0
  globalThis.clearTimeout = globalThis.clearInterval = () => {}
}
globalThis.queueMicrotask = fn => Promise.resolve().then(fn)
