import { NextResponse } from 'next/server'
import { HEX_64_RE } from './constants'

/** Escape text for safe embedding in HTML. */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

/**
 * Side-effect-free confirm page for SafeLinks / prefetch.
 * No Edge calls, no auto-submit — human POST only.
 */
export function confirmContinueHtml(opts: {
  actionPath: string
  title: string
  body: string
  buttonLabel?: string
}): string {
  const action = escapeHtml(opts.actionPath)
  const title = escapeHtml(opts.title)
  const body = escapeHtml(opts.body)
  const button = escapeHtml(opts.buttonLabel ?? 'Continuar')
  return `<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="robots" content="noindex, nofollow" />
  <meta name="referrer" content="no-referrer" />
  <title>${title}</title>
  <style>
    :root { color-scheme: light; }
    body {
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      font-family: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
      color: #14213d;
      background:
        radial-gradient(900px 500px at 10% -10%, #e8f2ee 0%, transparent 55%),
        #f7f4ef;
    }
    main {
      width: min(28rem, calc(100% - 2rem));
      text-align: center;
    }
    h1 { font-size: 1.5rem; font-weight: 600; margin: 0 0 0.75rem; }
    p { color: #5c667a; margin: 0 0 1.5rem; line-height: 1.5; }
    button {
      appearance: none; border: 0; border-radius: 0.5rem;
      background: #1b6b5a; color: #fff; font: inherit; font-weight: 600;
      padding: 0.75rem 1.25rem; cursor: pointer;
    }
    button:hover { filter: brightness(1.05); }
  </style>
</head>
<body>
  <main>
    <h1>${title}</h1>
    <p>${body}</p>
    <form method="post" action="${action}">
      <button type="submit">${button}</button>
    </form>
  </main>
</body>
</html>`
}

export function sterileHead(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'Cache-Control': 'private, no-store',
      'X-Robots-Tag': 'noindex, nofollow',
    },
  })
}

export function sterileConfirmGet(
  req: Request,
  token: string,
  opts: {
    invalidRedirect: string
    title: string
    body: string
    buttonLabel?: string
  },
): Response {
  const normalized = (token ?? '').trim().toLowerCase()
  if (!HEX_64_RE.test(normalized)) {
    return NextResponse.redirect(new URL(opts.invalidRedirect, req.url), 303)
  }
  const actionPath = new URL(req.url).pathname
  const html = confirmContinueHtml({
    actionPath,
    title: opts.title,
    body: opts.body,
    buttonLabel: opts.buttonLabel,
  })
  return new NextResponse(html, {
    status: 200,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'private, no-store',
      'X-Robots-Tag': 'noindex, nofollow',
      'Referrer-Policy': 'no-referrer',
    },
  })
}
