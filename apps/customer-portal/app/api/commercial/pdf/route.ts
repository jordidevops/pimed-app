import { NextResponse } from 'next/server'
import { resolveCommercialSession } from '@/lib/resolver'
import { readActorCookie, readSessionCookie } from '@/lib/session'

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

type PdfAction =
  | 'get_quote_or_agreement'
  | 'get_delivery_note'
  | 'get_invoice'
  | 'get_pending_decision'

function parseAction(raw: string | null): PdfAction | null {
  if (
    raw === 'get_quote_or_agreement' ||
    raw === 'get_delivery_note' ||
    raw === 'get_invoice' ||
    raw === 'get_pending_decision'
  ) {
    return raw
  }
  return null
}

export async function GET(req: Request) {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  if (!session || (actor !== 'grant' && actor !== 'staff')) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }

  const url = new URL(req.url)
  const action = parseAction(url.searchParams.get('action'))
  const id = url.searchParams.get('id')
  const itemKindRaw = url.searchParams.get('item_kind')
  const itemKind =
    itemKindRaw === 'agreement' || itemKindRaw === 'document'
      ? itemKindRaw
      : null

  if (!action || !id || !UUID_RE.test(id)) {
    return NextResponse.json({ error: 'invalid' }, { status: 400 })
  }

  const result = await resolveCommercialSession({
    sessionToken: session,
    action,
    targetId: id,
    itemKind,
    includePdfUrl: true,
  })

  const pdfUrl =
    action === 'get_pending_decision'
      ? result.ok
        ? result.pending_detail?.pdf_url
        : undefined
      : result.ok
        ? result.detail?.pdf_url
        : undefined

  if (!result.ok || !pdfUrl) {
    return NextResponse.json({ error: 'not_found' }, { status: 404 })
  }

  return NextResponse.redirect(pdfUrl, 302)
}
