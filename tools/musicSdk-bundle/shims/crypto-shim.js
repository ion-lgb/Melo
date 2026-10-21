// Node `crypto` 的 JSC shim：语义覆盖原版 musicSdk 用到的全部 API，
// 底层调用 Swift 注入的 __meloNative（macOS Security/CryptoKit/CommonCrypto）。
import { Buffer } from 'buffer'

const native = globalThis.__meloNative
if (!native) throw new Error('fatal: globalThis.__meloNative is missing')

const toBytes = value => {
  if (value instanceof Uint8Array) return Array.prototype.slice.call(value)
  if (Array.isArray(value)) return value.map(n => n & 0xff)
  if (typeof value === 'string') return Array.from(Buffer.from(value, 'utf8'))
  return []
}

function makeHash(algorithm) {
  const chunks = []
  return {
    update(data) {
      chunks.push(toBytes(data))
      return this
    },
    digest(encoding) {
      const bytes = chunks.flat()
      const hex = native.hash(String(algorithm), bytes)
      if (hex == null) throw new Error(`hash failed: ${algorithm}`)
      if (!encoding || encoding === 'hex') return hex
      if (encoding === 'buffer') return Buffer.from(hex, 'hex')
      if (encoding === 'base64') return Buffer.from(hex, 'hex').toString('base64')
      throw new TypeError(`Unknown encoding: ${encoding}`)
    },
  }
}

export const createHash = algorithm => makeHash(algorithm)

const normalizeMode = mode => {
  const normalized = String(mode).toLowerCase()
  if (!/^aes-(128|192|256)-(cbc|ecb)$/.test(normalized)) {
    throw new Error(`不支持的加密模式: ${mode}`)
  }
  return normalized
}

class Cipher {
  constructor(encryption, mode, key, iv) {
    this.encryption = encryption
    this.mode = normalizeMode(mode)
    this.key = toBytes(key)
    this.iv = toBytes(iv)
    this.chunks = []
    this.length = 0
  }
  update(data) {
    const bytes = toBytes(data)
    this.chunks.push(bytes)
    this.length += bytes.length
    return Buffer.alloc(0)
  }
  final() {
    // 大响应（如排行榜列表）用逐字节合并，避免 spread 导致调用栈溢出
    const merged = new Uint8Array(this.length)
    let offset = 0
    for (const chunk of this.chunks) {
      merged.set(chunk, offset)
      offset += chunk.length
    }
    const output = this.encryption
      ? native.aesEncrypt(Array.from(merged), this.mode, this.key, this.iv)
      : native.aesDecrypt(Array.from(merged), this.mode, this.key, this.iv)
    if (output == null) throw new Error(`${this.encryption ? '加密' : '解密'}失败: ${this.mode}`)
    return Buffer.from(output)
  }
  // Node 的 setAutoPadding(false) 在本 shim 中不需要（原版代码未使用）
  setAutoPadding() { return this }
}

export const createCipheriv = (mode, key, iv) => new Cipher(true, mode, key, iv)
export const createDecipheriv = (mode, key, iv) => new Cipher(false, mode, key, iv)

export const randomBytes = size => Buffer.from(native.randomBytes(Number(size) || 0))

export const publicEncrypt = (options, buffer) => {
  const key = options && options.key
  if (typeof key !== 'string') throw new Error('publicEncrypt 仅支持 PEM 字符串公钥')
  const output = native.rsaEncrypt(toBytes(buffer), key)
  if (output == null) throw new Error('RSA 加密失败')
  return Buffer.from(output)
}

export const constants = {
  RSA_NO_PADDING: 1,
  RSA_PKCS1_PADDING: 4,
  Z_NO_FLUSH: 0,
  Z_SYNC_FLUSH: 2,
  Z_FULL_FLUSH: 3,
  Z_FINISH: 4,
  Z_OK: 0,
  Z_BUF_ERROR: -5,
}

const crypto = {
  createHash, createCipheriv, createDecipheriv, randomBytes, publicEncrypt, constants,
}

export default crypto
