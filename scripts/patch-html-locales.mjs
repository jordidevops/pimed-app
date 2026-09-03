#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const migPath = path.join(root, 'supabase/migrations/20260617000001_seed_extra_document_templates.sql')
const loc = readFileSync(path.join(root, 'scripts/seed-html-locales-016-028.sql'), 'utf8')
let mig = readFileSync(migPath, 'utf8')

const marker = "('70000000-0000-0000-0000-000000000028', NULL, 'Certificat de lliurament'"
const idx = mig.indexOf(marker)
if (idx < 0) throw new Error('template 028 not found')
const afterTpl = mig.indexOf('ON CONFLICT (id) DO NOTHING;', idx)
if (afterTpl < 0) throw new Error('conflict end not found')
const insertAt = afterTpl + 'ON CONFLICT (id) DO NOTHING;'.length

if (mig.includes('71000000-0000-0000-0000-000000000016')) {
  console.log('HTML locales 016-028 already present')
  process.exit(0)
}

mig = mig.slice(0, insertAt) + '\n\n' + loc + mig.slice(insertAt)
writeFileSync(migPath, mig)
console.log('Patched migration with HTML locales 016-028')
