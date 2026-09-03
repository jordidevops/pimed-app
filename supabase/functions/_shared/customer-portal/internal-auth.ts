const HEADER_NAME = "X-Customer-Portal-Bff-Secret";

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

/**
 * Authenticates the customer-portal BFF before an endpoint parses request data.
 * Both configured credentials are always compared to avoid exposing which
 * rotation slot matched.
 */
export async function requireCustomerPortalBffAuth(
  req: Request,
): Promise<Response | null> {
  const supplied = req.headers.get(HEADER_NAME) ?? "";
  const primary = Deno.env.get("CUSTOMER_PORTAL_BFF_SECRET") ?? "";
  const previous = Deno.env.get("CUSTOMER_PORTAL_BFF_SECRET_PREVIOUS") ?? "";

  const [suppliedDigest, primaryDigest, previousDigest] = await Promise.all([
    digest(supplied),
    digest(primary),
    digest(previous),
  ]);
  const primaryMatches =
    primary.length > 0 && constantTimeEqual(suppliedDigest, primaryDigest);
  const previousMatches =
    previous.length > 0 && constantTimeEqual(suppliedDigest, previousDigest);

  return primaryMatches || previousMatches ? null : unauthorized();
}
