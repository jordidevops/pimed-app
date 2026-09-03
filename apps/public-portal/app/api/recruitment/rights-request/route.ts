/**
 * POST /api/recruitment/rights-request
 * Body: { siteId, email, requestType, message?, website? }
 */

import { NextRequest, NextResponse } from 'next/server'
import { z } from 'zod'
import { createPortalClient } from '@/lib/supabase'
import { checkRateLimit } from '@/lib/rate-limit'

const Schema = z.object({
  siteId: z.string().uuid(),
  email: z.string().email().max(200),
  requestType: z.enum([
    'access',
    'erasure',
    'rectification',
    'restriction',
    'portability',
    'objection',
  ]),
  message: z.string().max(2000).optional().nullable(),
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

    if (parsed.data.website && parsed.data.website.trim() !== '') {
      return NextResponse.json({ ok: true }, { status: 200 })
    }

    const withinLimit = await checkRateLimit(
      `rights-req:${getClientIp(req)}`,
      10,
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
    const { data, error } = await db.rpc('submit_applicant_data_request', {
      p_public_site_id: parsed.data.siteId,
      p_email: parsed.data.email.trim().toLowerCase(),
      p_request_type: parsed.data.requestType,
      p_message: parsed.data.message?.trim() || null,
    })

    if (error) {
      const normalized = [error.code, error.message, error.details, error.hint]
        .filter(Boolean)
        .join(' | ')
        .toLowerCase()
      if (normalized.includes('email_not_verified')) {
        return NextResponse.json(
          {
            error: 'email_not_verified',
            message:
              'Cal verificar el correu de la candidatura abans d\'exercir drets.',
          },
          { status: 400 },
        )
      }
      if (normalized.includes('invalid_email') || normalized.includes('invalid_request')) {
        return NextResponse.json(
          { error: 'validation_error', message: 'Dades invàlides.' },
          { status: 422 },
        )
      }
      console.error('[api/recruitment/rights-request] RPC:', error)
      return NextResponse.json(
        { error: 'internal_error', message: 'Error intern.' },
        { status: 500 },
      )
    }

    return NextResponse.json(data ?? { ok: true }, { status: 200 })
  } catch (err) {
    console.error('[api/recruitment/rights-request] Unhandled:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern.' },
      { status: 500 },
    )
  }
}
