#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const orig = readFileSync(path.join(root, 'tmp/original-seed-templates.sql'), 'utf8')
const ACME_TENANT = '10000000-0000-0000-0000-000000000001'
const acmeNums = new Set([8, 9, 10, 11, 12, 13, 14])

function isAcmeTuple(tuple) {
  if (tuple.includes(ACME_TENANT)) return true
  const nums = [...tuple.matchAll(/000000000(\d{3})'/g)].map((m) => parseInt(m[1], 10))
  if (nums.length >= 2) return acmeNums.has(nums[1])
  return nums.length === 1 && acmeNums.has(nums[0])
}

function acmeOnlyBlock(block) {
  const vi = block.indexOf('VALUES')
  const ci = block.indexOf('ON CONFLICT')
  const head = block.slice(0, vi + 6)
  const tail = block.slice(ci)
  const body = block.slice(vi + 6, ci)
  const isMulti = body.includes("\n  '71000000") || body.includes("\n  '73000000")
  const tuples = isMulti
    ? [...body.matchAll(/\(\s*\n\s*'7[13]000000[\s\S]*?\n\s*true\s*\)/g)].map((x) => x[0].trim())
    : body.split('\n').filter((l) => l.trim().startsWith('(')).map((l) => l.replace(/,\s*$/, ''))
  const drop = tuples.filter(isAcmeTuple)
  if (!drop.length) return ''
  return `${head}\n${drop.join(',\n')}\n${tail}`
}

const parts = []
for (const block of orig.split(/(?=INSERT INTO data\.)/)) {
  if (!block.startsWith('INSERT INTO')) continue
  const acme = acmeOnlyBlock(block)
  if (acme) parts.push(acme)
}

const acmeSection = `-- ─── B4b. Plantilles documentals demo (Acme Corp, 008-014) ─────────────────
-- No són plantilles de plataforma; requereix tenant i perfils creats abans (B1-B3).

${parts.join('\n\n')}
`

let seed = readFileSync(path.join(root, 'supabase/seed.sql'), 'utf8')
const marker = '-- ─── B4/B5. Plantilles de documents'
const b6 = '-- ─── B6. Departaments'
const start = seed.indexOf(marker)
const end = seed.indexOf(b6)
if (start < 0 || end < 0) throw new Error('seed markers not found')
seed = seed.slice(0, start) + seed.slice(start, end).split('\n').slice(0, 4).join('\n') + '\n\n' + acmeSection + '\n' + seed.slice(end)
writeFileSync(path.join(root, 'supabase/seed.sql'), seed)
console.log('Acme inserts:', parts.length)
