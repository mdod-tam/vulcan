const esbuild = require('esbuild')

const isWatch = process.argv.includes('--watch')

const buildOptions = {
  entryPoints: ['app/javascript/application.js'],
  bundle: true,
  sourcemap: true,
  format: 'esm',
  outdir: 'app/assets/builds',
  publicPath: '/assets',
  resolveExtensions: ['.js', '.ts', '.jsx', '.tsx'],
  loader: {
    '.js': 'jsx',
    '.png': 'file',
    '.jpg': 'file',
    '.jpeg': 'file',
    '.gif': 'file',
    '.svg': 'file',
  },
  define: {
    'process.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV || process.env.RAILS_ENV || 'development')
  }
}

if (isWatch) {
  esbuild.context(buildOptions).then(ctx => ctx.watch())
} else {
  esbuild.build(buildOptions).catch(() => process.exit(1))
} 