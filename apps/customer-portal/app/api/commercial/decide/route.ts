import { NextResponse } from 'next/server'
import {
  acceptPendingDecision,
  continuePendingDocuseal,
  declinePendingDecision,
  resolvePendingDecisionDetail,
} from '@/lib/resolver'
import { readActorCookie, readSessionCookie } from '@/lib/session'

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export async function POST(req: Request) {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  if (!session) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }
  if (actor === 'staff') {
    return NextResponse.json({ error: 'forbidden' }, { status: 403 })
  }
  if (actor !== 'grant') {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }

  let body: {
    request_id?: string
    action?: string
    reason?: string | null
    actor_name?: string | null
    actor_role?: string | null
    signature_base64?: string | null
  }
  try {
    body = (await req.json()) as typeof body
  } catch {
    return NextResponse.json({ error: 'invalid_body' }, { status: 400 })
  }

  if (!body.request_id || !UUID_RE.test(body.request_id)) {
    return NextResponse.json({ error: 'invalid_target' }, { status: 400 })
  }

  if (body.action === 'status') {
    const result = await resolvePendingDecisionDetail({
      sessionToken: session,
      requestId: body.request_id,
    })
    if (!result.ok || !result.pending_detail) {
      return NextResponse.json(
        { error: result.ok === false ? result.error : 'not_found' },
        { status: result.ok === false ? (result.status === 403 ? 403 : 404) : 404 },
      )
    }
    const d = result.pending_detail
    return NextResponse.json({
      ok: true,
      request_id: d.request_id,
      status: d.status,
      decided_via: d.decided_via ?? null,
      decided_at: d.decided_at ?? null,
      provider_continue_available: d.provider_continue_available === true,
      decline_available: d.decline_available === true,
      accept_available: d.accept_available === true,
      can_decide: d.can_decide === true,
      receipt: d.receipt ?? null,
    })
  }

  if (body.action === 'continue_docuseal') {
    const result = await continuePendingDocuseal({
      sessionToken: session,
      requestId: body.request_id,
    })

    if (!result.ok) {
      const status =
        result.status === 400 ||
        result.status === 403 ||
        result.status === 409 ||
        result.status === 502
          ? result.status
          : result.status >= 500
            ? 502
            : 404
      return NextResponse.json({ error: result.error }, { status })
    }

    if (result.already_decided === true) {
      return NextResponse.json({
        ok: true,
        request_id: result.request_id,
        already_decided: true,
        status: result.status,
        decided_via: result.decided_via ?? null,
        decided_at: result.decided_at ?? null,
      })
    }

    return NextResponse.json({
      ok: true,
      request_id: result.request_id,
      redirect_url: result.redirect_url,
    })
  }

  if (body.action === 'decline') {
    const result = await declinePendingDecision({
      sessionToken: session,
      requestId: body.request_id,
      reason: body.reason ?? null,
      actorName: body.actor_name ?? null,
      actorRole: body.actor_role ?? null,
      clientOpId: crypto.randomUUID(),
    })

    if (!result.ok) {
      const status =
        result.status === 400 || result.status === 403 || result.status === 409
          ? result.status
          : result.status >= 500
            ? 502
            : 404
      return NextResponse.json({ error: result.error }, { status })
    }

    if (result.status !== 'accepted' && result.status !== 'declined') {
      return NextResponse.json(
        { error: 'apply_failed', status: result.status ?? null },
        { status: 409 },
      )
    }

    return NextResponse.json({
      ok: true,
      request_id: result.request_id,
      status: result.status,
      applied: result.applied === true,
      already_decided: result.already_decided === true,
      decided_via: result.decided_via ?? null,
      decided_at: result.decided_at ?? null,
    })
  }

  if (body.action === 'accept') {
    const signature = typeof body.signature_base64 === 'string'
      ? body.signature_base64.trim()
      : ''
    if (!signature) {
      return NextResponse.json({ error: 'missing_signature' }, { status: 400 })
    }

    const result = await acceptPendingDecision({
      sessionToken: session,
      requestId: body.request_id,
      signatureBase64: signature,
      actorName: body.actor_name ?? null,
      actorRole: body.actor_role ?? null,
    })

    if (!result.ok) {
      const status =
        result.status === 400 ||
        result.status === 403 ||
        result.status === 409 ||
        result.status === 502
          ? result.status
          : result.status >= 500
            ? 502
            : 404
      return NextResponse.json({ error: result.error }, { status })
    }

    if (result.status !== 'accepted' && result.status !== 'declined') {
      return NextResponse.json(
        { error: 'apply_failed', status: result.status ?? null },
        { status: 409 },
      )
    }

    return NextResponse.json({
      ok: true,
      request_id: result.request_id,
      status: result.status,
      applied: result.applied === true,
      already_decided: result.already_decided === true,
      decided_via: result.decided_via ?? null,
      decided_at: result.decided_at ?? null,
    })
  }

  return NextResponse.json({ error: 'outcome_not_supported' }, { status: 400 })
}
