/*
 * Melo · LX Music 自定义源脚本运行时 shim（JavaScriptCore）
 *
 * 在裸 JSContext 中复刻原版 Electron preload.js
 * （src/main/modules/userApi/renderer/preload.js）暴露给自定义源脚本的
 * `window.lx` 语义，并补齐脚本在 Chromium renderer 里能用到的最小浏览器平台：
 *   - EVENT_NAMES { request, inited, updateAlert }
 *   - lx.send / lx.on（inited 仅一次、updateAlert 仅一次且限长）
 *   - lx.request(url, options, callback) -> cancel；resp 形态与 preload 一致
 *   - lx.utils.buffer / crypto(aesEncrypt, rsaEncrypt, randomBytes, md5) / zlib
 *   - lx.version = '2.0.0'、env = 'desktop'、currentScriptInfo
 *   - inited 事件按应用白名单过滤 sources/actions/qualitys
 *   - 应用 -> 脚本 request 事件：强制返回 Promise，并按 preload 规则校验
 *     musicUrl / lyric / pic 的结果
 *
 * Swift 侧原生原语由 globalThis.__native 提供（见 Sources/MeloJS/JSContextRuntime.swift），
 * 本文件不包含任何内建音源，只提供运行时胶水。
 */
(function () {
  'use strict'

  var N = globalThis.__native
  if (!N) throw new Error('fatal: native bridge (globalThis.__native) is missing')

  var g = globalThis
  g.window = g
  g.self = g
  g.global = g
  g.window.globalThis = g

  // ---------------------------------------------------------------- console
  function stringifyArg (a) {
    if (typeof a === 'string') return a
    if (a instanceof Error) return a.stack || (a.name + ': ' + a.message)
    if (typeof a === 'undefined') return 'undefined'
    if (typeof a === 'function') return '[Function ' + (a.name || 'anonymous') + ']'
    try {
      var s = JSON.stringify(a)
      return s === undefined ? String(a) : s
    } catch (e) {
      return String(a)
    }
  }
  function formatArgs (args) {
    var out = []
    for (var i = 0; i < args.length; i++) out.push(stringifyArg(args[i]))
    return out.join(' ')
  }
  function mkLog (level) {
    return function () { N.log(level, formatArgs(arguments)) }
  }
  g.console = {
    log: mkLog('log'),
    info: mkLog('info'),
    warn: mkLog('warn'),
    error: mkLog('error'),
    debug: mkLog('debug'),
    trace: mkLog('trace')
  }

  // ----------------------------------------------------------------- timers
  // JSC has no setTimeout/setInterval/queueMicrotask (verified: all undefined).
  var nextTimerId = 0
  var activeTimers = {}
  function makeTimer (fn, delay, repeat, args) {
    var id = ++nextTimerId
    activeTimers[id] = true
    var cb = function () {
      if (!activeTimers[id]) return
      try {
        if (typeof fn === 'function') fn.apply(g, args)
        else (0, eval)(String(fn))
      } catch (e) {
        console.error('timer callback error:', e)
      }
    }
    N.timerStart(id, cb, Number(delay) || 0, !!repeat)
    return id
  }
  g.setTimeout = function (fn, delay) {
    return makeTimer(fn, delay, false, Array.prototype.slice.call(arguments, 2))
  }
  g.setInterval = function (fn, delay) {
    return makeTimer(fn, delay, true, Array.prototype.slice.call(arguments, 2))
  }
  g.clearTimeout = g.clearInterval = function (id) {
    delete activeTimers[id]
    N.timerCancel(id)
  }
  g.setImmediate = function (fn) {
    return makeTimer(fn, 0, false, Array.prototype.slice.call(arguments, 1))
  }
  g.clearImmediate = g.clearTimeout
  g.queueMicrotask = function (fn) {
    Promise.resolve().then(function () {
      try { fn() } catch (e) { console.error('queueMicrotask error:', e) }
    })
  }

  // ------------------------------------------------------- Binary primitives
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  function bytesToBase64 (bytes) {
    var out = ''
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i] & 0xff
      var b1 = i + 1 < bytes.length ? bytes[i + 1] & 0xff : 0
      var b2 = i + 2 < bytes.length ? bytes[i + 2] & 0xff : 0
      out += B64.charAt(b0 >> 2)
      out += B64.charAt(((b0 & 3) << 4) | (b1 >> 4))
      out += i + 1 < bytes.length ? B64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '='
      out += i + 2 < bytes.length ? B64.charAt(b2 & 63) : '='
    }
    return out
  }
  function base64ToBytes (str) {
    var clean = String(str).replace(/[^A-Za-z0-9+/=]/g, '')
    var out = []
    for (var i = 0; i < clean.length; i += 4) {
      var c0 = B64.indexOf(clean.charAt(i))
      var c1 = B64.indexOf(clean.charAt(i + 1))
      var c2 = B64.indexOf(clean.charAt(i + 2))
      var c3 = B64.indexOf(clean.charAt(i + 3))
      if (c0 < 0 || c1 < 0) break
      out.push(((c0 << 2) | (c1 >> 4)) & 0xff)
      if (c2 >= 0) out.push(((c1 << 4) | (c2 >> 2)) & 0xff)
      if (c3 >= 0) out.push(((c2 << 6) | c3) & 0xff)
    }
    return out
  }
  function bytesToHex (bytes) {
    var s = ''
    for (var i = 0; i < bytes.length; i++) s += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16)
    return s
  }
  function hexToBytes (str) {
    var s = String(str).replace(/[^0-9a-fA-F]/g, '')
    var out = []
    for (var i = 0; i + 1 < s.length; i += 2) out.push(parseInt(s.substr(i, 2), 16))
    return out
  }
  function utf8Encode (str) {
    var bytes = []
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i)
      if (c < 0x80) bytes.push(c)
      else if (c < 0x800) {
        bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f))
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i)
        var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00)
        bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f))
      } else {
        bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f))
      }
    }
    return bytes
  }
  function utf8Decode (bytes) {
    var out = ''
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i++]
      if (b < 0x80) {
        out += String.fromCharCode(b)
      } else if ((b & 0xe0) === 0xc0) {
        out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f))
      } else if ((b & 0xf0) === 0xe0) {
        out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f))
      } else {
        var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)
        cp -= 0x10000
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
      }
    }
    return out
  }
  function asBytes (v) {
    if (v instanceof Uint8Array) return Array.prototype.slice.call(v)
    if (Array.isArray(v)) return v.map(function (n) { return n & 0xff })
    return []
  }

  // --------------------------------------------------------- Buffer polyfill
  // Hand-written subset of Node Buffer on top of Uint8Array. Covers the API
  // surface used by musicSdk and typical custom sources. Replacing this with
  // feross/buffer (bundled, MIT) is the production recommendation.
  class Buffer extends Uint8Array {
    static from (value, encodingOrOffset, length) {
      if (typeof value === 'string') return Buffer.fromString(value, encodingOrOffset)
      if (value instanceof ArrayBuffer) {
        return new Buffer(value, Number(encodingOrOffset) || 0, length === undefined ? undefined : Number(length))
      }
      if (ArrayBuffer.isView(value) || Array.isArray(value)) {
        var src = ArrayBuffer.isView(value)
          ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
          : value
        var out = new Buffer(src.length)
        for (var i = 0; i < src.length; i++) out[i] = src[i] & 0xff
        return out
      }
      if (value && typeof value === 'object' && typeof value.length === 'number') {
        var out2 = new Buffer(value.length)
        for (var j = 0; j < value.length; j++) out2[j] = value[j] & 0xff
        return out2
      }
      throw new TypeError('The first argument must be of type string or an instance of Buffer, ArrayBuffer, or Array')
    }
    static fromString (str, encoding) {
      var enc = String(encoding || 'utf8').toLowerCase()
      var bytes
      if (enc === 'utf8' || enc === 'utf-8') bytes = utf8Encode(str)
      else if (enc === 'hex') bytes = hexToBytes(str)
      else if (enc === 'base64') bytes = base64ToBytes(str)
      else if (enc === 'binary' || enc === 'latin1' || enc === 'ascii') {
        bytes = []
        for (var i = 0; i < str.length; i++) bytes.push(str.charCodeAt(i) & 0xff)
      } else if (enc === 'utf16le' || enc === 'ucs2' || enc === 'ucs-2') {
        bytes = []
        for (var k = 0; k < str.length; k++) {
          bytes.push(str.charCodeAt(k) & 0xff, (str.charCodeAt(k) >> 8) & 0xff)
        }
      } else throw new TypeError('Unknown encoding: ' + enc)
      return Buffer.from(bytes)
    }
    static alloc (size, fill) {
      var b = new Buffer(Number(size) || 0)
      if (fill !== undefined && fill !== 0) b.fill(fill)
      return b
    }
    static allocUnsafe (size) { return new Buffer(Number(size) || 0) }
    static isBuffer (v) { return v instanceof Buffer }
    static byteLength (str, encoding) {
      return Buffer.fromString(String(str), encoding).length
    }
    static concat (list, totalLength) {
      var total = 0
      for (var i = 0; i < list.length; i++) total += list[i].length
      if (totalLength !== undefined) total = Number(totalLength)
      var out = new Buffer(total)
      var offset = 0
      for (var j = 0; j < list.length && offset < total; j++) {
        var chunk = list[j]
        var n = Math.min(chunk.length, total - offset)
        for (var k = 0; k < n; k++) out[offset + k] = chunk[k] & 0xff
        offset += n
      }
      return out
    }
    toString (encoding, start, end) {
      var enc = String(encoding === undefined ? 'utf8' : encoding).toLowerCase()
      var s = start === undefined ? 0 : Number(start)
      var e = end === undefined ? this.length : Number(end)
      var view = this.subarray(s, e)
      if (enc === 'utf8' || enc === 'utf-8') return utf8Decode(view)
      if (enc === 'hex') return bytesToHex(view)
      if (enc === 'base64') return bytesToBase64(view)
      if (enc === 'binary' || enc === 'latin1' || enc === 'ascii') {
        var out = ''
        for (var i = 0; i < view.length; i++) out += String.fromCharCode(view[i])
        return out
      }
      throw new TypeError('Unknown encoding: ' + enc)
    }
    toJSON () { return { type: 'Buffer', data: Array.prototype.slice.call(this) } }
    slice (start, end) {
      var begin = start === undefined ? 0 : Number(start)
      var finish = end === undefined ? this.length : Number(end)
      if (begin < 0) begin = Math.max(this.length + begin, 0)
      if (finish < 0) finish = Math.max(this.length + finish, 0)
      begin = Math.min(begin, this.length)
      finish = Math.min(Math.max(finish, begin), this.length)
      return new Buffer(this.buffer, this.byteOffset + begin, finish - begin)
    }
    subarray (start, end) { return this.slice(start, end) }
    write (string, offset, length, encoding) {
      var enc = typeof length === 'string' ? length : encoding
      var off = Number(offset) || 0
      var bytes = Buffer.fromString(String(string), enc)
      var n = Math.min(bytes.length, this.length - off, length === undefined || typeof length === 'string' ? Infinity : Number(length))
      for (var i = 0; i < n; i++) this[off + i] = bytes[i]
      return n
    }
    equals (other) {
      var b = Buffer.isBuffer(other) ? other : Buffer.from(other)
      if (b.length !== this.length) return false
      for (var i = 0; i < this.length; i++) if (this[i] !== b[i]) return false
      return true
    }
    indexOf (needle, byteOffset, encoding) {
      var from = Number(byteOffset) || 0
      if (from < 0) from = Math.max(this.length + from, 0)
      var target
      if (typeof needle === 'number') target = [needle & 0xff]
      else if (typeof needle === 'string') target = Buffer.fromString(needle, encoding)
      else target = asBytes(needle)
      if (target.length === 0) return Math.min(from, this.length)
      for (var i = from; i <= this.length - target.length; i++) {
        var ok = true
        for (var j = 0; j < target.length; j++) {
          if (this[i + j] !== target[j]) { ok = false; break }
        }
        if (ok) return i
      }
      return -1
    }
    includes (needle, byteOffset, encoding) { return this.indexOf(needle, byteOffset, encoding) !== -1 }
    fill (value, start, end) {
      var s = start === undefined ? 0 : Number(start)
      var e = end === undefined ? this.length : Number(end)
      if (typeof value === 'string') {
        var bytes = Buffer.fromString(value)
        for (var i = s; i < e; i++) this[i] = bytes[(i - s) % bytes.length]
      } else if (value instanceof Uint8Array) {
        for (var j = s; j < e; j++) this[j] = value[(j - s) % value.length]
      } else {
        Uint8Array.prototype.fill.call(this, value & 0xff, s, e)
      }
      return this
    }
    copy (target, targetStart, sourceStart, sourceEnd) {
      var ts = targetStart === undefined ? 0 : Number(targetStart)
      var ss = sourceStart === undefined ? 0 : Number(sourceStart)
      var se = sourceEnd === undefined ? this.length : Number(sourceEnd)
      var n = Math.min(se - ss, target.length - ts)
      for (var i = 0; i < n; i++) target[ts + i] = this[ss + i]
      return n
    }
    readUInt8 (offset) { return this[Number(offset) || 0] }
    readInt8 (offset) { var v = this[Number(offset) || 0]; return v > 127 ? v - 256 : v }
    readUInt16BE (offset) { var o = Number(offset) || 0; return (this[o] << 8) | this[o + 1] }
    readUInt16LE (offset) { var o = Number(offset) || 0; return this[o] | (this[o + 1] << 8) }
    readUInt32BE (offset) { var o = Number(offset) || 0; return ((this[o] << 24) >>> 0) + ((this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]) }
    readUInt32LE (offset) { var o = Number(offset) || 0; return ((this[o + 3] << 24) >>> 0) + ((this[o + 2] << 16) | (this[o + 1] << 8) | this[o]) }
    writeUInt8 (value, offset) { this[Number(offset) || 0] = value & 0xff; return (Number(offset) || 0) + 1 }
    writeUInt16BE (value, offset) { var o = Number(offset) || 0; this[o] = (value >> 8) & 0xff; this[o + 1] = value & 0xff; return o + 2 }
    writeUInt16LE (value, offset) { var o = Number(offset) || 0; this[o] = value & 0xff; this[o + 1] = (value >> 8) & 0xff; return o + 2 }
    writeUInt32BE (value, offset) {
      var o = Number(offset) || 0
      this[o] = (value >>> 24) & 0xff; this[o + 1] = (value >>> 16) & 0xff
      this[o + 2] = (value >>> 8) & 0xff; this[o + 3] = value & 0xff
      return o + 4
    }
    writeUInt32LE (value, offset) {
      var o = Number(offset) || 0
      this[o] = value & 0xff; this[o + 1] = (value >>> 8) & 0xff
      this[o + 2] = (value >>> 16) & 0xff; this[o + 3] = (value >>> 24) & 0xff
      return o + 4
    }
  }
  g.Buffer = Buffer
  if (!g.ArrayBuffer) throw new Error('fatal: no ArrayBuffer')

  // Browser platform bits that were missing in bare JSC but exist in the real
  // (Chromium renderer) execution environment of custom source scripts.
  g.atob = function (str) {
    return String.fromCharCode.apply(null, base64ToBytes(str))
  }
  g.btoa = function (str) {
    var bytes = []
    for (var i = 0; i < str.length; i++) bytes.push(str.charCodeAt(i) & 0xff)
    return bytesToBase64(bytes)
  }
  class TextEncoder {
    get encoding () { return 'utf-8' }
    encode (str) { return Uint8Array.from(utf8Encode(String(str === undefined ? '' : str))) }
  }
  class TextDecoder {
    constructor (label) { this.encoding = label || 'utf-8' }
    decode (buf) {
      if (!buf) return ''
      if (buf instanceof ArrayBuffer) return utf8Decode(new Uint8Array(buf))
      return utf8Decode(asBytes(buf))
    }
  }
  g.TextEncoder = TextEncoder
  g.TextDecoder = TextDecoder
  g.navigator = {
    userAgent: 'Mozilla/5.0 (Macintosh; MeloJSC PoC) AppleWebKit/537.36 (KHTML, like Gecko) Melo/2.12.6',
    platform: 'MacIntel',
    language: 'zh-CN'
  }
  g.location = { href: 'about:blank', protocol: 'about:', host: '' }
  function fakeElement () {
    return {
      setAttribute: function () {},
      style: {},
      appendChild: function () {},
      removeChild: function () {},
      parentNode: null
    }
  }
  g.document = {
    createElement: fakeElement,
    body: { appendChild: function () {}, removeChild: function () {} },
    getElementById: function () { return null },
    addEventListener: function () {},
    removeEventListener: function () {}
  }
  g.performance = { now: function () { return Date.now() - (g.__meloRuntimeStartTime || 0) } }
  g.crypto = {
    getRandomValues: function (arr) {
      var bytes = N.randomBytes(arr.length)
      arr.set(bytes)
      return arr
    }
  }
  g.addEventListener = function () {}
  g.removeEventListener = function () {}

  // ------------------------------------------------------------- HTTP bridge
  // JS-side bookkeeping mirrors preload.js: native returns a response payload,
  // this layer builds {statusCode, statusMessage, headers, bytes, raw, body}
  // and JSON-parses body when possible.
  var httpCallbacks = {}
  var nextHttpId = 0
  function nativeRequest (url, options, cb) {
    var id = ++nextHttpId
    httpCallbacks[id] = cb
    var opts = options || {}
    var payload = {
      method: opts.method || 'get',
      headers: opts.headers || {},
      body: opts.body,
      form: opts.form,
      formData: opts.formData,
      timeout: typeof opts.timeout === 'number' ? opts.timeout : undefined
    }
    N.httpRequest(id, String(url), JSON.stringify(payload))
    var cancelled = false
    return function cancel () {
      if (cancelled) return
      cancelled = true
      if (!httpCallbacks[id]) return
      N.httpCancel(id) // callback stays registered; native delivers an 'aborted' error
    }
  }
  g.__nativeHttpResponse = function (id, errMsg, payloadJSON) {
    var cb = httpCallbacks[id]
    if (!cb) return
    delete httpCallbacks[id]
    if (errMsg) {
      cb(new Error(String(errMsg)), null, null)
      return
    }
    try {
      var p = JSON.parse(payloadJSON)
      var raw = Buffer.from(p.bodyBase64 || '', 'base64')
      var text = raw.toString('utf8')
      var body = text
      try { body = JSON.parse(text) } catch (e) {}
      var resp = {
        statusCode: p.statusCode,
        statusMessage: p.statusMessage,
        headers: p.headers || {},
        bytes: p.bytes || raw.length,
        raw: raw,
        body: body
      }
      cb(null, resp, body)
    } catch (e) {
      cb(e, null, null)
    }
  }

  // ----------------------------------------------------------------- window.lx
  var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' }
  var eventNames = [EVENT_NAMES.request, EVENT_NAMES.inited, EVENT_NAMES.updateAlert]
  var allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local']
  var supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: []
  }
  var supportActions = {
    kw: ['musicUrl'], kg: ['musicUrl'], tx: ['musicUrl'], wy: ['musicUrl'],
    mg: ['musicUrl'], xm: ['musicUrl'], local: ['musicUrl', 'lyric', 'pic']
  }
  var isInitedApi = false
  var isShowedUpdateAlert = false
  var requestHandler = null

  function filterSources (info) {
    if (!info) throw new Error('Missing required parameter init info')
    var sourceInfo = { sources: {} }
    for (var i = 0; i < allSources.length; i++) {
      var source = allSources[i]
      var userSource = info.sources && info.sources[source]
      if (!userSource || userSource.type !== 'music') continue
      var qualitys = supportQualitys[source]
      var actions = supportActions[source]
      var filteredActions = actions.filter(function (a) { return userSource.actions && userSource.actions.indexOf(a) > -1 })
      var filteredQualitys = qualitys.filter(function (q) { return userSource.qualitys && userSource.qualitys.indexOf(q) > -1 })
      var capability = {
        type: 'music',
        actions: filteredActions,
        qualitys: filteredQualitys
      }
      if (typeof userSource.name === 'string' && userSource.name) capability.name = userSource.name
      sourceInfo.sources[source] = capability
    }
    return sourceInfo
  }

  function sendEvent (eventName, data) {
    return new Promise(function (resolve, reject) {
      if (eventNames.indexOf(eventName) === -1) {
        return reject(new Error('The event is not supported: ' + eventName))
      }
      if (eventName === EVENT_NAMES.inited) {
        if (isInitedApi) return reject(new Error('Script is inited'))
        isInitedApi = true
        var sourceInfo
        try {
          sourceInfo = filterSources(data)
        } catch (e) {
          N.send('initFailed', JSON.stringify({ message: e.message }))
          return reject(e)
        }
        if (data.openDevTools === true) N.send('openDevTools', '{}')
        var r = N.send('inited', JSON.stringify({
          status: data.status !== false,
          message: typeof data.message === 'string' ? data.message : null,
          openDevTools: data.openDevTools === true,
          sources: sourceInfo.sources
        }))
        if (String(r).indexOf('error:') === 0) return reject(new Error(String(r).slice(6)))
        resolve()
        return
      }
      if (eventName === EVENT_NAMES.updateAlert) {
        if (isShowedUpdateAlert) return reject(new Error('The update alert can only be called once.'))
        isShowedUpdateAlert = true
        if (!data || typeof data !== 'object') return reject(new Error('parameter format error.'))
        if (!data.log || typeof data.log !== 'string') return reject(new Error('log is required.'))
        var log = data.log.length > 1024 ? data.log.substring(0, 1024) + '...' : data.log
        var updateUrl = data.updateUrl
        if (updateUrl && (typeof updateUrl !== 'string' || !/^https?:\/\/[^\s$.?#].[^\s]*$/.test(updateUrl) || updateUrl.length > 1024)) updateUrl = undefined
        N.send('updateAlert', JSON.stringify({ log: log, updateUrl: updateUrl }))
        resolve()
        return
      }
      reject(new Error('Unknown event name: ' + eventName))
    })
  }

  function onEvent (eventName, handler) {
    if (eventNames.indexOf(eventName) === -1) {
      return Promise.reject(new Error('The event is not supported: ' + eventName))
    }
    if (eventName === EVENT_NAMES.request) {
      if (typeof handler !== 'function') return Promise.reject(new Error('handler must be a function'))
      requestHandler = handler
      N.setRequestHandler(handler)
      return Promise.resolve()
    }
    return Promise.reject(new Error('The event is not supported: ' + eventName))
  }

  function lxRequest (url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {} }
    options = options || {}
    if (typeof callback !== 'function') throw new TypeError('callback must be a function')
    return nativeRequest(url, options, function (err, resp, body) {
      if (err) callback.call(g, err, null, null)
      else callback.call(g, null, resp, body)
    })
  }

  function toByteArray (v) {
    if (v instanceof Uint8Array) return Array.prototype.slice.call(v)
    if (Array.isArray(v)) return v.map(function (n) { return n & 0xff })
    if (typeof v === 'string') return Array.prototype.slice.call(Buffer.fromString(v, 'binary'))
    return []
  }

  var utils = {
    crypto: {
      aesEncrypt: function (buffer, mode, key, iv) {
        var out = N.aesEncrypt(toByteArray(buffer), String(mode), toByteArray(key), toByteArray(iv || []))
        if (out === null || out === undefined) throw new Error('aesEncrypt failed')
        return Buffer.from(out)
      },
      rsaEncrypt: function (buffer, key) {
        var out = N.rsaEncrypt(toByteArray(buffer), String(key))
        if (out === null || out === undefined) throw new Error('rsaEncrypt failed')
        return Buffer.from(out)
      },
      randomBytes: function (size) { return Buffer.from(N.randomBytes(Number(size) || 0)) },
      md5: function (str) { return String(N.md5(String(str))) }
    },
    buffer: {
      from: function () { return Buffer.from.apply(Buffer, arguments) },
      bufToString: function (buf, format) { return Buffer.from(buf, 'binary').toString(format) }
    },
    zlib: {
      inflate: function (buf) {
        return new Promise(function (resolve, reject) {
          var r = N.zlibInflate(toByteArray(buf))
          if (!r || !r.ok) return reject(new Error((r && r.error) || 'inflate failed'))
          resolve(Buffer.from(r.data))
        })
      },
      deflate: function (data) {
        return new Promise(function (resolve, reject) {
          var r = N.zlibDeflate(toByteArray(data))
          if (!r || !r.ok) return reject(new Error((r && r.error) || 'deflate failed'))
          resolve(Buffer.from(r.data))
        })
      }
    }
  }

  var scriptInfo = {}
  try { scriptInfo = JSON.parse(N.scriptInfo()) } catch (e) {}

  var lx = {
    EVENT_NAMES: EVENT_NAMES,
    request: lxRequest,
    send: sendEvent,
    on: onEvent,
    utils: utils,
    currentScriptInfo: scriptInfo,
    version: '2.0.0',
    env: 'desktop'
  }
  g.lx = lx
  g.window.lx = lx

  g.__meloRuntimeStartTime = Date.now()

  // fetch() shim over the same native HTTP bridge. The real script window is
  // a Chromium renderer, but user-api.html CSP is `default-src 'none'`, so
  // fetch/XHR cannot reach the network there anyway; scripts must use lx.request.
  g.fetch = function (url, options) {
    options = options || {}
    return new Promise(function (resolve, reject) {
      nativeRequest(url, {
        method: options.method || 'get',
        headers: options.headers || {},
        body: options.body,
        timeout: options.timeout
      }, function (err, resp) {
        if (err) return reject(err)
        var text = resp.raw.toString('utf8')
        var headersObj = {}
        Object.keys(resp.headers || {}).forEach(function (k) { headersObj[k.toLowerCase()] = resp.headers[k] })
        resolve({
          ok: resp.statusCode >= 200 && resp.statusCode < 300,
          status: resp.statusCode,
          statusText: resp.statusMessage || '',
          headers: {
            get: function (name) { return headersObj[String(name).toLowerCase()] === undefined ? null : headersObj[String(name).toLowerCase()] },
            has: function (name) { return headersObj[String(name).toLowerCase()] !== undefined },
            forEach: function (fn) { Object.keys(headersObj).forEach(function (k) { fn(headersObj[k], k) }) }
          },
          text: function () { return Promise.resolve(text) },
          json: function () { return Promise.resolve().then(function () { return JSON.parse(text) }) },
          arrayBuffer: function () {
            var bytes = Buffer.from(resp.raw).buffer
            return Promise.resolve(bytes)
          }
        })
      })
    })
  }

  // ------------------------------------------------ app -> script event entry
  // Swift calls these via evaluateScript. They mirror preload.js handleRequest:
  // call the registered handler, require a Promise, validate the musicUrl result.
  g.__pending = {}
  g.__safeJSON = function (v) {
    try {
      if (v === undefined) return 'null'
      return JSON.stringify(v)
    } catch (e) { return JSON.stringify(String(v)) }
  }
  g.__track = function (promise, tag) {
    g.__pending[tag] = { state: 'pending' }
    Promise.resolve(promise).then(function (v) {
      g.__pending[tag] = { state: 'resolved', json: g.__safeJSON(v) }
    }, function (e) {
      g.__pending[tag] = { state: 'rejected', message: String((e && e.message) || e) }
    })
  }
  function verifyLyricInfo (info) {
    if (typeof info != 'object' || typeof info.lyric != 'string') throw new Error('failed')
    if (info.lyric.length > 51200) throw new Error('failed')
    return {
      lyric: info.lyric,
      tlyric: (typeof info.tlyric == 'string' && info.tlyric.length < 5120) ? info.tlyric : null,
      rlyric: (typeof info.rlyric == 'string' && info.rlyric.length < 5120) ? info.rlyric : null,
      lxlyric: (typeof info.lxlyric == 'string' && info.lxlyric.length < 8192) ? info.lxlyric : null
    }
  }
  // 与 preload.js handleRequest 对齐：handler 必须返回 Promise；按 action 校验结果
  g.__lxDispatchRequestJSON = function (json) {
    var data = JSON.parse(json)
    if (!requestHandler) return Promise.reject(new Error('Request event is not defined'))
    return Promise.resolve().then(function () {
      var response = requestHandler.call(g, { source: data.source, action: data.action, info: data.info })
      if (!response || typeof response.then !== 'function') {
        throw new Error('The request event handler must return a Promise')
      }
      return response
    }).then(function (response) {
      if (data.action === 'musicUrl') {
        if (typeof response !== 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
        return { source: data.source, action: data.action, data: { type: data.info.type, url: response } }
      }
      if (data.action === 'lyric') {
        return { source: data.source, action: data.action, data: verifyLyricInfo(response) }
      }
      if (data.action === 'pic') {
        if (typeof response !== 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
        return { source: data.source, action: data.action, data: response }
      }
      throw new Error('Unsupported action: ' + data.action)
    })
  }
})()
