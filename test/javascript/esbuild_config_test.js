import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const config = path.resolve(__dirname, '../../esbuild.config.js')
let fixture

beforeEach(() => {
  fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'vulcan-build-test-'))
  fs.mkdirSync(path.join(fixture, 'app/javascript'), { recursive: true })
  fs.mkdirSync(path.join(fixture, 'app/assets/builds'), { recursive: true })
  fs.writeFileSync(path.join(fixture, 'app/javascript/application.js'), 'console.log(process.env.NODE_ENV)\n')
  fs.writeFileSync(path.join(fixture, 'app/assets/builds/application.js.map'), 'stale development map')
})

afterEach(() => fs.rmSync(fixture, { recursive: true, force: true }))

test.each([
  ['production', 'development'],
  ['development', 'production'],
  ['production', ''],
  ['development', 'development']
])('build artifacts respect RAILS_ENV=%s and NODE_ENV=%s', (rails, node) => {
  execFileSync(process.execPath, [config], {
    cwd: fixture, env: { ...process.env, RAILS_ENV: rails, NODE_ENV: node }
  })
  const production = rails === 'production' || node === 'production'
  const bundle = fs.readFileSync(path.join(fixture, 'app/assets/builds/application.js'), 'utf8')
  expect(bundle).toContain(production ? 'production' : 'development')
  expect(bundle.includes('sourceMappingURL')).toBe(!production)
  expect(fs.existsSync(path.join(fixture, 'app/assets/builds/application.js.map'))).toBe(!production)
  if (production) expect(bundle.trim().split('\n')).toHaveLength(1)
})
