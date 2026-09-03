import { readFileSync, readdirSync } from 'node:fs'
import { extname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const roots = ['app', 'components', 'lib']
const runtimeExtensions = new Set(['.js', '.jsx', '.mjs', '.ts', '.tsx'])
const forbidden = 'SUPABASE_' + 'SERVICE_ROLE_KEY'
const violations = []

function scan(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isDirectory()) {
      scan(path)
    } else if (runtimeExtensions.has(extname(entry.name))) {
      const source = readFileSync(path, 'utf8')
      if (source.includes(forbidden)) violations.push(path)
    }
  }
}

for (const root of roots) scan(fileURLToPath(new URL(`${root}/`, import.meta.url)))

if (violations.length > 0) {
  console.error(`Forbidden service-role reference in customer-portal runtime:\n${violations.join('\n')}`)
  process.exit(1)
}
