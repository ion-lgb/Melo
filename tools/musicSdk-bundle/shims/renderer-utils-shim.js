// 渲染层工具函数 shim：替代 src/renderer/utils/index.ts（原文件会拖入 Vue/store/DOMParser）。
// 只实现 musicSdk 会导入的 7 个函数，逻辑与原版一致。
import { createHash } from 'crypto'

const numFix = num => (num < 10 ? '0' + num : num)

export const sizeFormate = size => {
  if (!size) return '0 B'
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  const number = Math.floor(Math.log(size) / Math.log(1024))
  return `${(size / Math.pow(1024, Math.floor(number))).toFixed(2)} ${units[number]}`
}

const toDateObj = date => {
  if (!date) return null
  if (typeof date === 'string') {
    if (/^\d+$/.test(date)) date = parseInt(date)
    else if (date.includes('-')) return new Date(date.replace(/-/g, '/'))
    else return new Date(date)
  }
  if (typeof date === 'number') return new Date(date)
  if (date instanceof Date) return date
  return null
}

export const dateFormat = (_date, format = 'Y-M-D h:m:s') => {
  const date = toDateObj(_date)
  if (!date || Number.isNaN(date.getTime())) return ''
  return format
    .replace('Y', date.getFullYear().toString())
    .replace('M', numFix(date.getMonth() + 1))
    .replace('D', numFix(date.getDate()))
    .replace('h', numFix(date.getHours()))
    .replace('m', numFix(date.getMinutes()))
    .replace('s', numFix(date.getSeconds()))
}

export const dateFormat2 = time => {
  const differ = Math.trunc((Date.now() - time) / 1000)
  if (differ < 60) return `${differ}秒前`
  if (differ < 3600) return `${Math.trunc(differ / 60)}分钟前`
  if (differ < 86400) return `${Math.trunc(differ / 3600)}小时前`
  return dateFormat(time)
}

export const formatPlayTime = time => {
  const m = Math.trunc(time / 60)
  const s = Math.trunc(time % 60)
  return m === 0 && s === 0 ? '--/--' : numFix(m) + ':' + numFix(s)
}

export const formatPlayCount = num => {
  if (num > 100000000) return `${Math.trunc(num / 10000000) / 10}亿`
  if (num > 10000) return `${Math.trunc(num / 1000) / 10}万`
  return String(num)
}

export const toMD5 = str => createHash('md5').update(str).digest('hex')

const namedEntities = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', hellip: '…', middot: '·', mdash: '—',
}

// 原版 decodeName 用 DOMParser 解码 HTML 实体并去掉标签；JSC 无 DOM，用等价实现。
export const decodeName = (str = '') => {
  if (!str) return ''
  return String(str)
    .replace(/<[^>]*>/g, '')
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)))
    .replace(/&([a-z]+);/gi, (match, name) => namedEntities[name] ?? match)
    .replace(/&amp;/g, '&')
}

export default {
  sizeFormate, dateFormat, dateFormat2, formatPlayTime, formatPlayCount, toMD5, decodeName,
}
