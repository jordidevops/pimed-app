import { writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildQt3SeedSql } from './platformCommercialHtml'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../../../')
const out = resolve(root, 'supabase/migrations/20261164000001_commercial_templates_seed_html.sql')
writeFileSync(out, buildQt3SeedSql(), 'utf8')
console.log(`Wrote ${out}`)
