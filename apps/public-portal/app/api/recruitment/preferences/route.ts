/**
 * POST /api/recruitment/preferences
 * Body: { token, choice, talentMonths?, website? (honeypot) }
 */

import { NextRequest, NextResponse } from 'next/server'
import { z } from 'zod'
import { createPortalClient } from '@/lib/supabase'
import { checkRateLimit } from '@/lib/rate-limit'

const Schema = z.object({
  token: z.string().min(16).max(200),
  choice: z.enum(['erase', 'talent_pool', 'keep_until_purge']),
  talentMonths: z.number().int().min(1).max(60).optional().nullable(),
  website: z.string().max(200).optional().nullable(),
})

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-vercel-forwarded-for') ??
    req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ??
    'unknown'
  )
}

export async function POST(req: NextRequest): Promise<NextResponse> {
  try {
    const raw = await req.json()
    const parsed = Schema.safeParse(raw)
    if (!parsed.success) {
      return NextResponse.json(
        { error: 'validation_error', message: 'Dades invàlides.' },
        { status: 422 },
      )
    }

    // Honeypot: bots fill hidden field
    if (parsed.data.website && parsed.data.website.trim() !== '') {
      return NextResponse.json({ ok: true }, { status: 200 })
    }

    const withinLimit = await checkRateLimit(
      `prefs:${getClientIp(req)}`,
      15,
      60_000,
    )
    if (!withinLimit) {
      return NextResponse.json(
        { error: 'rate_limited', message: 'Massa peticions.' },
        { status: 429 },
      )
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const db = createPortalClient() as any
    const { data, error } = await db.rpc('submit_post_rejection_preferences', {
      p_token: parsed.data.token,
      p_choice: parsed.data.choice,
      p_talent_months:
        parsed.data.choice === 'talent_pool'
          ? (parsed.data.talentMonths ?? null)
          : null,
    })

    if (error) {
      const normalized = [error.code, error.message, error.details, error.hint]
        .filter(Boolean)
        .join(' | ')
        .toLowerCase()
      if (
        normalized.includes('invalid_token') ||
        normalized.includes('invalid_or_expired')
      ) {
        return NextResponse.json(
          {
            error: 'invalid_token',
            message: "L'enllaç no és vàlid, ha caducat o ja s'ha usat.",
          },
          { status: 400 },
        )
      }
      if (normalized.includes('email_not_verified')) {
        return NextResponse.json(
          {
            error: 'email_not_verified',
            message: 'Cal verificar el correu abans de gestionar preferències.',
          },
          { status: 400 },
        )
      }
      if (normalized.includes('invalid_choice')) {
        return NextResponse.json(
          { error: 'invalid_choice', message: 'Opció no vàlida.' },
          { status: 422 },
        )
      }
      console.error('[api/recruitment/preferences] RPC:', error)
      return NextResponse.json(
        { error: 'internal_error', message: 'Error intern.' },
        { status: 500 },
      )
    }

    return NextResponse.json(data ?? { ok: true }, { status: 200 })
  } catch (err) {
    console.error('[api/recruitment/preferences] Unhandled:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern.' },
      { status: 500 },
    )
  }
}
