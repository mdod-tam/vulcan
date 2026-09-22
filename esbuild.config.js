const esbuild = require('esbuild')

const environment = process.env.NODE_ENV || process.env.RAILS_ENV || 'development'
const isProduction = environment === 'production'

const isWatch = process.argv.includes('--watch')

const buildOptions = {
  entryPoints: ['app/javascript/application.js'],
  bundle: true,
  minify: isProduction,
  sourcemap: !isProduction,
  format: 'esm',
  outdir: 'app/assets/builds',
  publicPath: '/assets',
  define: {
    'process.env.NODE_ENV': JSON.stringify(environment)
  }
}

// Remove a previous development map before assets are published.
if (isProduction) {
  require('node:fs').rmSync('app/assets/builds/application.js.map', { force: true })
}

if (isWatch) {
  esbuild.context(buildOptions).then(ctx => ctx.watch())
} else {
  esbuild.build(buildOptions).catch(() => process.exit(1))
}
