/**
 * POST /api/recruitment/verify
 * Body: { token }
 */

import { NextRequest, NextResponse } from 'next/server'
import { z } from 'zod'
import { createPortalClient } from '@/lib/supabase'
import { checkRateLimit } from '@/lib/rate-limit'

const Schema = z.object({
  token: z.string().min(16).max(200),
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
        { error: 'validation_error', message: 'Token invàlid.' },
        { status: 422 },
      )
    }

    const withinLimit = await checkRateLimit(
      `verify:${getClientIp(req)}`,
      20,
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
    const { data, error } = await db.rpc('verify_applicant_email', {
      p_token: parsed.data.token,
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
            message: 'L\'enllaç no és vàlid o ha caducat.',
          },
          { status: 400 },
        )
      }
      console.error('[api/recruitment/verify] RPC:', error)
      return NextResponse.json(
        { error: 'internal_error', message: 'Error intern.' },
        { status: 500 },
      )
    }

    return NextResponse.json(data ?? { ok: true }, { status: 200 })
  } catch (err) {
    console.error('[api/recruitment/verify] Unhandled:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern.' },
      { status: 500 },
    )
  }
}
