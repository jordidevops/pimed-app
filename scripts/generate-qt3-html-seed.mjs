#!/usr/bin/env node
/**
 * Regenera supabase/migrations/20261164000001_commercial_templates_seed_html.sql
 * des dels constructors HTML de tenant-portal (QT-3).
 *
 * Ús: node scripts/generate-qt3-html-seed.mjs
 */
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const result = spawnSync(
  'npx',
  ['vite-node', 'src/features/commercial/templates/writeQt3SeedSql.ts'],
  {
    cwd: path.join(root, 'apps/tenant-portal'),
    stdio: 'inherit',
    shell: true,
  },
)
process.exit(result.status ?? 1)
