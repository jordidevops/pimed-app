/**
 * GET /api/recruitment/rights-export?token=
 * Art. 15/20 export download (anon token; multi-download within TTL).
 * HEAD does not consume the token (email prefetch / link checkers).
 */

import { NextRequest, NextResponse } from 'next/server'
import { createPortalClient } from '@/lib/supabase'
import { checkRateLimit } from '@/lib/rate-limit'

function getClientIp(req: NextRequest): string {
  return (
    req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-vercel-forwarded-for') ??
    req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ??
    'unknown'
  )
}

export async function HEAD(): Promise<NextResponse> {
  return new NextResponse(null, {
    status: 204,
    headers: { 'Cache-Control': 'no-store' },
  })
}

export async function GET(req: NextRequest): Promise<NextResponse> {
  try {
    const token = req.nextUrl.searchParams.get('token')
    if (!token || token.length < 16) {
      return NextResponse.json(
        { error: 'invalid_token', message: 'Token invàlid.' },
        { status: 400 },
      )
    }

    const withinLimit = await checkRateLimit(
      `rights-export:${getClientIp(req)}`,
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
    const { data, error } = await db.rpc('fetch_rights_export', {
      p_token: token,
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
            message: "L'enllaç no és vàlid, ha caducat o s'ha esgotat.",
          },
          { status: 400 },
        )
      }
      console.error('[api/recruitment/rights-export] RPC:', error)
      return NextResponse.json(
        { error: 'internal_error', message: 'Error intern.' },
        { status: 500 },
      )
    }

    const payload = (data as { payload?: unknown } | null)?.payload
    const remaining = (data as { downloads_remaining?: number } | null)
      ?.downloads_remaining
    const body = JSON.stringify(payload ?? data, null, 2)
    return new NextResponse(body, {
      status: 200,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Disposition': 'attachment; filename="applicant-data-export.json"',
        'Cache-Control': 'no-store',
        ...(typeof remaining === 'number'
          ? { 'X-Downloads-Remaining': String(remaining) }
          : {}),
      },
    })
  } catch (err) {
    console.error('[api/recruitment/rights-export] Unhandled:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern.' },
      { status: 500 },
    )
  }
}
