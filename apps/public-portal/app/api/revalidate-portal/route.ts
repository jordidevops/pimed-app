import { revalidatePath } from 'next/server'
import { NextRequest, NextResponse } from 'next/server'

export async function POST(req: NextRequest) {
  const secret = req.headers.get('x-revalidate-secret')
  const expected = process.env.REVALIDATE_PORTAL_SECRET

  if (!expected || secret !== expected) {
    return NextResponse.json({ ok: false, code: 'unauthorized' }, { status: 401 })
  }

  let body: { paths?: string[] }
  try {
    body = await req.json()
  } catch {
    return NextResponse.json({ ok: false, code: 'invalid_body' }, { status: 400 })
  }

  const paths = body.paths ?? []
  if (!Array.isArray(paths) || paths.length === 0) {
    return NextResponse.json({ ok: false, code: 'paths_required' }, { status: 400 })
  }

  for (const p of paths) {
    if (typeof p === 'string' && p.startsWith('/')) {
      revalidatePath(p)
    }
  }

  return NextResponse.json({ ok: true, revalidated: paths })
}
