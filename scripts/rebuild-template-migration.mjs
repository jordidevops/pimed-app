#!/usr/bin/env node
/**
 * Rebuild production template migration + Acme demo section in seed.sql.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const orig = readFileSync(path.join(root, 'tmp/original-seed-templates.sql'), 'utf8')
const extraPath = path.join(root, 'supabase/migrations/20260617000001_seed_extra_document_templates.sql')
const docxNew = readFileSync(path.join(root, 'tmp/seed-docx-templates-016-028.sql'), 'utf8').trim()
const blockMapping = readFileSync(
  path.join(root, 'supabase/migrations/20260616000001_fix_seed_template_block_mappings.sql'),
  'utf8',
).replace(/^--[^\n]*\n/, '')

const ACME_TENANT = '10000000-0000-0000-0000-000000000001'
const acmeNums = [8, 9, 10, 11, 12, 13, 14]

function isAcmeId(id) {
  const n = parseInt(id.slice(-3), 10)
  return acmeNums.includes(n)
}

function isAcmeContent(text) {
  if (text.includes(ACME_TENANT)) return true
  const nums = [...text.matchAll(/000000000(\d{3})'/g)].map((m) => parseInt(m[1], 10))
  if (nums.length >= 2) return acmeNums.includes(nums[1])
  return nums.length === 1 && acmeNums.includes(nums[0])
}

function nullifyCreatedBy(text) {
  return text
    .replace(/, '20000000-0000-0000-0000-000000000001'/g, ', NULL')
    .replace(/, '20000000-0000-0000-0000-000000000002'/g, ', NULL')
}

function splitInsert(sql, { tupleMode = 'single' } = {}) {
  const valuesIdx = sql.indexOf('VALUES')
  const conflictIdx = sql.indexOf('ON CONFLICT')
  const head = sql.slice(0, valuesIdx + 'VALUES'.length)
  const body = sql.slice(valuesIdx + 'VALUES'.length, conflictIdx)
  const tail = sql.slice(conflictIdx)

  let tuples = []
  if (tupleMode === 'single') {
    tuples = body
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l.startsWith('('))
      .map((l) => l.replace(/,\s*$/, ''))
  } else {
    tuples = [...body.matchAll(/\(\s*\n\s*'7[13]000000[\s\S]*?\n\s*true\s*\)/g)].map((m) => m[0].trim())
  }

  const platform = []
  const acme = []
  for (const t of tuples) {
    if (isAcmeContent(t)) acme.push(t)
    else platform.push(nullifyCreatedBy(t))
  }

  const joinTuples = (arr) => (arr.length ? `\n${arr.join(',\n')}\n` : '\n')
  return {
    platformSql: platform.length ? head + joinTuples(platform) + tail : '',
    acmeSql: acme.length ? head + joinTuples(acme) + tail : '',
  }
}

// Split original seed blocks
const blocks = orig.split(/(?=INSERT INTO data\.)/)
const acmeParts = []
const platformParts = []

for (const block of blocks) {
  if (!block.trim()) continue
  if (block.includes('document_template_locales')) {
    const { platformSql, acmeSql } = splitInsert(block, { tupleMode: 'multi' })
    if (platformSql) platformParts.push(platformSql)
    if (acmeSql) acmeParts.push(acmeSql)
  } else if (block.includes('document_templates')) {
    const { platformSql, acmeSql } = splitInsert(block, { tupleMode: 'single' })
    if (platformSql) platformParts.push(platformSql)
    if (acmeSql) acmeParts.push(acmeSql)
  } else {
    platformParts.push(block)
  }
}

// Extra HTML 016-028 + date updates from broken migration (if still valid)
let extra = readFileSync(extraPath, 'utf8')
const dateSection = extra.match(
  /-- ── Format de dates Liquid[\s\S]*?(?=-- ── Noves plantilles HTML 016-028)/,
)?.[0]
const newHtmlSection = extra.match(
  /-- ── Noves plantilles HTML 016-028[\s\S]*?ON CONFLICT \(id\) DO NOTHING;/,
)?.[0]
const newHtmlLocales = readFileSync(
  path.join(root, 'scripts/seed-html-locales-016-028.sql'),
  'utf8',
).trim()

const header = `-- =============================================================================
-- Seed de plantilles documentals de plataforma (producció)
-- HTML/DOCX 001-007, 015-028 + default_block_mapping
-- Demo Acme 008-014 → supabase/seed.sql (requereix tenant de prova)
-- =============================================================================

`

const migration =
  header +
  platformParts.join('\n\n') +
  '\n\n' +
  (dateSection ?? '') +
  '\n' +
  (newHtmlSection ?? '') +
  '\n\n' +
  newHtmlLocales +
  '\n\n-- ── B5c. Plantilles DOCX 016-028 ───────────────────────────────────────────\n' +
  nullifyCreatedBy(docxNew) +
  '\n\n-- ── default_block_mapping (consolidat) ─────────────────────────────────────\n' +
  blockMapping.trim() +
  '\n'

writeFileSync(extraPath, migration)

const acmeSection = `-- ─── B4b. Plantilles documentals demo (Acme Corp, 008-014) ─────────────────
-- No són plantilles de plataforma; requereix tenant i perfils creats abans (B1-B3).

${acmeParts.join('\n\n')}
`

let seed = readFileSync(path.join(root, 'supabase/seed.sql'), 'utf8')
seed = seed.replace(
  /-- ─── B4b\. Plantilles documentals demo[\s\S]*?(?=-- ─── B6\. Departaments)/,
  '',
)
seed = seed.replace(
  /(-- ─── B4\/B5\. Plantilles de documents[\s\S]*?generate-docx-seed\.mjs\n)\n(?=-- ─── B6\. Departaments)/,
  `$1\n${acmeSection}\n`,
)
writeFileSync(path.join(root, 'supabase/seed.sql'), seed)

console.log('Migration lines:', migration.split('\n').length)
console.log('Acme blocks:', acmeParts.length)
