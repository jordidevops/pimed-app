/**
 * Verifica un token de Cloudflare Turnstile contra l'API siteverify.
 *
 * Ús al Route Handler:
 *   const ok = await verifyTurnstileToken(token, request.headers.get('CF-Connecting-IP'))
 *   if (!ok) return NextResponse.json({ error: 'turnstile_failed' }, { status: 422 })
 *
 * Per a tests locals, usa les claus de test de Cloudflare:
 *   Secret: 1x0000000000000000000000000000000AA  (sempre passa)
 *   Site:   1x00000000000000000000AA              (sempre passa)
 *
 * Docs: https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
 */

const SITEVERIFY_URL =
  "https://challenges.cloudflare.com/turnstile/v0/siteverify";

/**
 * Verifica el token Turnstile rebut del formulari.
 * @param token - el token `cf-turnstile-response` del formulari
 * @param remoteIp - IP del visitant (opcional però recomanat)
 * @returns true si el token és vàlid, false en qualsevol error o fallada
 */
export async function verifyTurnstileToken(
  token: string,
  remoteIp?: string | null,
): Promise<boolean> {
  const secret = process.env.TURNSTILE_SECRET_KEY;
  const failOpen = process.env.TURNSTILE_FAIL_OPEN === "true";

  if (!secret) {
    // En dev local sense clau configurada, deixa passar per no bloquejar el dev
    if (process.env.NODE_ENV === "development") {
      console.warn(
        "[turnstile] TURNSTILE_SECRET_KEY no configurada. Saltant verificació en dev.",
      );
      return true;
    }
    console.error("[turnstile] TURNSTILE_SECRET_KEY no configurada en producció.");
    return false;
  }

  if (!token || token.length === 0) {
    return false;
  }

  try {
    const body = new URLSearchParams({
      secret,
      response: token,
    });
    if (remoteIp) {
      body.set("remoteip", remoteIp);
    }

    const resp = await fetch(SITEVERIFY_URL, {
      method: "POST",
      body,
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      // Timeout de 5s per no bloquejar el formulari
      signal: AbortSignal.timeout(5000),
    });

    if (!resp.ok) return false;

    const json = (await resp.json()) as { success: boolean };
    return json.success === true;
  } catch (err) {
    console.error("[turnstile] Error verificant token:", err);
    // En producció, millor fail-closed per evitar bypass massiu.
    // Si cal mode fail-open temporal per incidència externa, usar TURNSTILE_FAIL_OPEN=true.
    if (process.env.NODE_ENV === "development" || failOpen) {
      return true;
    }
    return false;
  }
}
