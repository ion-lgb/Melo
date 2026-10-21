// 把原版 LX Music musicSdk（kw/kg/tx/wy/mg 元数据源）打包为 JavaScriptCore IIFE bundle。
//
// 用法：cd macos/tools/musicSdk-bundle && npm install && npm run build
// 产物：macos/Resources/js/musicSdk.bundle.js（仓库内保留，App 运行不依赖 Node）
import { build } from 'esbuild'
import path from 'node:path'
import fs from 'node:fs'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const macosRoot = path.resolve(here, '../..')
const repoRoot = path.resolve(macosRoot, '..')
const srcRoot = path.join(repoRoot, 'src')
const shims = path.join(here, 'shims')
const outfile = path.join(macosRoot, 'Resources/js/musicSdk.bundle.js')

const alias = {
  crypto: path.join(shims, 'crypto-shim.js'),
  'node:crypto': path.join(shims, 'crypto-shim.js'),
  zlib: path.join(shims, 'zlib-shim.js'),
  dns: path.join(shims, 'dns-shim.js'),
  '@renderer/utils': path.join(shims, 'renderer-utils-shim.js'),
  '@renderer/store': path.join(shims, 'renderer-store-shim.js'),
  '@renderer/utils/musicSdk/kg/vendors/infSign.min': path.join(srcRoot, 'renderer/utils/musicSdk/kg/vendors/infSign.min.js'),
  '@common/utils/lyricUtils/kg': path.join(srcRoot, 'common/utils/lyricUtils/kg.js'),
  '@common/utils/lyricUtils/util': path.join(srcRoot, 'common/utils/lyricUtils/util.ts'),
  'crypto-js': path.join(shims, 'empty-shim.js'),
}

const plugin = {
  name: 'melo-musicSdk-aliases',
  setup(build) {
    build.onResolve({ filter: /.*/ }, args => {
      // 显式 alias（裸模块或带 @renderer/@common 前缀）
      if (alias[args.path]) return { path: alias[args.path] }
      if (args.path === 'crypto-js' || args.path.startsWith('crypto-js/')) {
        return { path: alias['crypto-js'] }
      }

      const importer = args.importer || ''
      const underMusicSdk = importer.includes('/src/renderer/utils/musicSdk/')

      // 原版渲染进程请求层：src/renderer/utils/request.js
      if (underMusicSdk && (args.path.endsWith('request') || args.path === '../../../request')) {
        return { path: path.join(shims, 'request-shim.js') }
      }
      // 原版渲染层工具 index（formatPlayTime/sizeFormate/decodeName/dateFormat...）
      // 仅匹配 '../../index' / '../../../index'，不要误伤 './utils/index' 这类源内部真实模块
      if (underMusicSdk && /^\.\.\/(\.\.\/)?index$/.test(args.path)) {
        return { path: path.join(shims, 'renderer-utils-shim.js') }
      }
      // 原版 message（请求错误文案）
      if (underMusicSdk && /(^|\/)message$/.test(args.path)) {
        return { path: path.join(shims, 'renderer-message-shim.js') }
      }
      // 原版 renderer/utils/env（仅被注释引用，兜底）
      if (underMusicSdk && /(^|\/)utils\/env$/.test(args.path)) {
        return { path: path.join(shims, 'renderer-env-shim.js') }
      }
      return undefined
    })
  },
}

fs.mkdirSync(path.dirname(outfile), { recursive: true })
const result = await build({
  absWorkingDir: here,
  entryPoints: [path.join(here, 'entry.js')],
  bundle: true,
  outfile,
  format: 'iife',
  platform: 'browser',
  target: ['es2020'],
  minify: true,
  sourcemap: false,
  legalComments: 'none',
  charset: 'utf8',
  logLevel: 'warning',
  plugins: [plugin],
  metafile: true,
  tsconfigRaw: '{}',
})

const size = fs.statSync(outfile).size
console.log(`[musicSdk-bundle] ${outfile}`)
console.log(`[musicSdk-bundle] size = ${(size / 1024).toFixed(1)} KiB (${size} bytes)`)
console.log(`[musicSdk-bundle] modules = ${Object.keys(result.metafile.inputs).length}`)
const warnings = result.warnings || []
if (warnings.length) {
  console.log(`[musicSdk-bundle] ${warnings.length} warning(s):`)
  for (const warning of warnings) console.log('  -', warning.text)
  process.exitCode = 1
}
