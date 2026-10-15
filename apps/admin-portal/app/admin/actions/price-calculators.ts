'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { assertBackofficeRole } from '@/lib/platform-catalog/server'
import {
  CHECKLIST_ARCHETYPES,
  asRecord,
  nullableStr,
  num,
  str,
  type ActionResult,
} from '@/lib/platform-catalog/constants'

const PATH = '/dashboard/settings/price-calculators'

const ARCHETYPE_SET = new Set<string>(CHECKLIST_ARCHETYPES)

export type PlatformCalculator = {
  id: string
  slug: string
  target_archetypes: string[]
  catalog_version: number
  tags: string[]
  is_active: boolean
  title: Record<string, string> | null
  summary: Record<string, string> | null
  updated_at: string | null
}

export type CalculatorCatalogSettings = {
  show_cross_archetype_catalog: boolean
}

function mapRow(raw: unknown): PlatformCalculator {
  const row = asRecord(raw)
  const title = row.title
  const summary = row.summary
  return {
    id: str(row.id),
    slug: str(row.slug),
    target_archetypes: Array.isArray(row.target_archetypes)
      ? (row.target_archetypes as unknown[]).map((a) => String(a))
      : [],
    catalog_version: num(row.catalog_version, 1),
    tags: Array.isArray(row.tags) ? (row.tags as unknown[]).map((t) => String(t)) : [],
    is_active: row.is_active !== false,
    title:
      title && typeof title === 'object' && !Array.isArray(title)
        ? (title as Record<string, string>)
        : null,
    summary:
      summary && typeof summary === 'object' && !Array.isArray(summary)
        ? (summary as Record<string, string>)
        : null,
    updated_at: nullableStr(row.updated_at),
  }
}

function sanitizeArchetypes(raw: string[] | undefined): string[] {
  const list = (raw ?? []).map((a) => a.trim()).filter((a) => ARCHETYPE_SET.has(a))
  return [...new Set(list)]
}

export async function listPlatformCalculators(): Promise<PlatformCalculator[]> {
  await assertBackofficeRole()
  const rows = await prisma.$queryRaw<Array<Record<string, unknown>>>`
    SELECT id, slug, target_archetypes, catalog_version, tags, is_active,
           title, summary, updated_at
    FROM data.calculator_catalog
    ORDER BY slug
  `
  return rows.map(mapRow)
}

export async function updatePlatformCalculatorVisibility(input: {
  id: string
  target_archetypes: string[]
  is_active: boolean
  title?: Record<string, string> | null
  summary?: Record<string, string> | null
}): Promise<ActionResult> {
  try {
    await assertBackofficeRole(['admin'])
    const archetypes = sanitizeArchetypes(input.target_archetypes)
    if (archetypes.length === 0) {
      return { ok: false, message: 'Cal almenys un arquetip' }
    }
    const archetypesJson = JSON.stringify(archetypes)
    const titleJson = JSON.stringify(input.title ?? {})
    const summaryJson = JSON.stringify(input.summary ?? {})
    await prisma.$executeRaw`
      UPDATE data.calculator_catalog
      SET target_archetypes = ARRAY(
            SELECT jsonb_array_elements_text(${archetypesJson}::jsonb)
          ),
          is_active = ${!!input.is_active},
          title = ${titleJson}::jsonb,
          summary = ${summaryJson}::jsonb,
          updated_at = now()
      WHERE id = ${input.id}::uuid
    `
    revalidatePath(PATH)
    return { ok: true, message: 'Calculadora actualitzada' }
  } catch (err) {
    return {
      ok: false,
      message: err instanceof Error ? err.message : 'Error desconegut',
    }
  }
}

export async function getCalculatorCatalogSettings(): Promise<CalculatorCatalogSettings> {
  await assertBackofficeRole()
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'commercial_calculators'
  `
  const settings = (rows[0]?.settings ?? {}) as Record<string, unknown>
  return {
    show_cross_archetype_catalog: settings.show_cross_archetype_catalog === true,
  }
}

export async function updateCalculatorCatalogSettings(
  next: CalculatorCatalogSettings,
): Promise<ActionResult> {
  try {
    const { userId } = await assertBackofficeRole(['admin'])
    const settings = {
      show_cross_archetype_catalog: !!next.show_cross_archetype_catalog,
    }
    await prisma.$executeRaw`
      INSERT INTO data.system_settings (module, settings, updated_by, updated_at)
      VALUES (
        'commercial_calculators',
        ${JSON.stringify(settings)}::jsonb,
        ${userId}::uuid,
        now()
      )
      ON CONFLICT (module) DO UPDATE
      SET settings = data.system_settings.settings || EXCLUDED.settings,
          updated_by = EXCLUDED.updated_by,
          updated_at = now()
    `
    revalidatePath(PATH)
    return { ok: true, message: 'Configuració desada' }
  } catch (err) {
    return {
      ok: false,
      message: err instanceof Error ? err.message : 'Error desconegut',
    }
  }
}
