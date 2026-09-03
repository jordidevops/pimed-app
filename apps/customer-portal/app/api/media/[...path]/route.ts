import { NextResponse } from 'next/server'
import { readActorCookie, readSessionCookie } from '@/lib/session'
import { streamReportMedia } from '@/lib/resolver'

type Params = { params: Promise<{ path: string[] }> }

export async function GET(req: Request, { params }: Params) {
  const session = await readSessionCookie()
  const actor = await readActorCookie()
  if (!session) {
    return NextResponse.json({ error: 'unauthorized' }, { status: 401 })
  }

  const url = new URL(req.url)
  const reportVersionId = url.searchParams.get('v') ?? undefined
  const forceDownload = url.searchParams.get('dl') === '1'
  if (actor === 'grant' && !reportVersionId) {
    return NextResponse.json({ error: 'not_found' }, { status: 404 })
  }

  const { path } = await params
  let objectKey: string
  try {
    objectKey = path.map(decodeURIComponent).join('/')
  } catch {
    return NextResponse.json({ error: 'invalid' }, { status: 400 })
  }
  if (!objectKey || objectKey.includes('..')) {
    return NextResponse.json({ error: 'invalid' }, { status: 400 })
  }

  const requestId = crypto.randomUUID()
  const upstream = await streamReportMedia({
    actorType: actor,
    sessionToken: session,
    objectKey,
    reportVersionId,
    range: req.headers.get('range') ?? undefined,
    requestId,
    userAgent: req.headers.get('user-agent') ?? undefined,
  })
  if (!upstream.ok || !upstream.body) {
    const status = upstream.status === 416 ? 416 : upstream.status >= 500 ? 502 : 404
    return NextResponse.json({ error: status === 502 ? 'upstream_error' : 'not_found' }, { status })
  }

  const headers = new Headers({
    'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Request-Id': requestId,
  })
  for (const name of [
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
    'etag',
    'last-modified',
  ]) {
    const value = upstream.headers.get(name)
    if (value) headers.set(name, value)
  }

  const contentType = (headers.get('content-type') ?? 'application/octet-stream')
    .split(';')[0]
    .trim()
    .toLowerCase()
  const inlineOk =
    !forceDownload &&
    ['image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/webp', 'image/avif'].includes(
      contentType,
    )
  const rawName = objectKey.split('/').pop() || 'file'
  const safeName = rawName.replace(/["\\\r\n]/g, '_').slice(0, 180) || 'file'
  headers.set(
    'Content-Disposition',
    `${inlineOk ? 'inline' : 'attachment'}; filename="${safeName}"`,
  )

  return new Response(upstream.body, { status: upstream.status, headers })
}
