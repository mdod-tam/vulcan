const esbuild = require('esbuild')

const isProduction = process.env.RAILS_ENV === 'production' || process.env.NODE_ENV === 'production'
const environment = isProduction ? 'production' : process.env.NODE_ENV || process.env.RAILS_ENV || 'development'

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

// esbuild leaves existing maps untouched when sourcemap is false.
// Production builds delete maps left by development builds.
if (isProduction) {
  require('node:fs').rmSync('app/assets/builds/application.js.map', { force: true })
}

if (isWatch) {
  esbuild.context(buildOptions).then(ctx => ctx.watch())
} else {
  esbuild.build(buildOptions).catch(() => process.exit(1))
}
