import QRCode from "npm:qrcode@1.5.4";
import { createAdminClient } from "../supabase.ts";
import { bytesToHex, sha256Bytes } from "./crypto.ts";
import {
  EMAIL_ATTACHMENTS_BUCKET,
  type EmailAttachmentRef,
} from "../email-attachments.ts";

export const PORTAL_QR_CONTENT_ID = "employee-portal-qr";

export interface SendPortalAccessEmailInput {
  tenant_id: string;
  employee_id: string;
  token_id: string;
  secret: string;
  recipient: string;
  recipient_override: boolean;
  requested_by_user_id: string | null;
  locale?: string;
  template_id?: string | null;
}

export interface ResolvedPublicSite {
  public_site_id: string;
  site_id: string | null;
  site_name: string | null;
  slug: string | null;
  canonical_domain: string | null;
  portal_base_url: string | null;
  fallback_used: boolean;
  tenant_slug: string;
}

interface EmployeeRow {
  id: string;
  tenant_id: string;
  site_id: string | null;
  full_name: string;
  email: string | null;
}

interface TokenLookupRow {
  token_id: string;
  employee_id: string;
  tenant_id: string;
  pin_required: boolean;
  pin_must_set?: boolean;
  expires_at: string | null;
  is_active: boolean;
  revoked_at: string | null;
}

interface TenantRow {
  name: string;
}

interface SiteRow {
  email_reply_to: string | null;
}

function firstName(fullName: string): string {
  const trimmed = fullName.trim();
  if (!trimmed) return "";
  return trimmed.split(/\s+/)[0] ?? trimmed;
}

function buildPortalBootstrapUrl(
  resolved: ResolvedPublicSite,
  secret: string,
): string {
  const base = resolved.portal_base_url?.replace(/\/$/, "") ||
    (resolved.slug && Deno.env.get("PUBLIC_PORTAL_SYSTEM_DOMAIN")
      ? `https://${resolved.slug}.public.${Deno.env.get("PUBLIC_PORTAL_SYSTEM_DOMAIN")}`
      : null);
  if (!base) {
    throw new AccessEmailError("portal_url_unavailable", 400);
  }
  return `${base}/e/${encodeURIComponent(secret)}`;
}

function pinInstructions(
  token: TokenLookupRow,
  locale: string,
): string {
  if (!token.pin_required) {
    return locale === "en"
      ? "No PIN is required, but keep this link private."
      : locale === "es"
      ? "No se requiere PIN, pero guarda este enlace en privado."
      : "No cal PIN, però guarda l'enllaç en privat.";
  }
  if (token.pin_must_set) {
    return locale === "en"
      ? "On first access you will set your own private PIN."
      : locale === "es"
      ? "En el primer acceso definirás tu propio PIN privado."
      : "Al primer accés definiràs el teu propi PIN privat.";
  }
  return locale === "en"
    ? "Your manager assigned a PIN for this link."
    : locale === "es"
    ? "Tu responsable te ha asignado un PIN para este enlace."
    : "El teu responsable t'ha assignat un PIN per a aquest enllaç.";
}

async function generateQrPng(url: string): Promise<Uint8Array> {
  const dataUrl = await QRCode.toDataURL(url, {
    width: 280,
    margin: 1,
    errorCorrectionLevel: "M",
  });
  const base64 = dataUrl.split(",")[1];
  if (!base64) throw new AccessEmailError("qr_generation_failed", 500);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export class AccessEmailError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "AccessEmailError";
  }
}

export async function sendEmployeePortalAccessEmail(
  input: SendPortalAccessEmailInput,
): Promise<{ email_log_id: string; portal_url: string }> {
  const admin = createAdminClient();
  const locale = input.locale ?? "ca";
  const secret = input.secret.trim();
  const recipient = input.recipient.trim().toLowerCase();

  if (!secret) throw new AccessEmailError("missing_secret", 400);
  if (!recipient || !recipient.includes("@")) {
    throw new AccessEmailError("invalid_recipient", 400);
  }

  const hashHex = bytesToHex(await sha256Bytes(secret));
  const { data: tokenData, error: tokenError } = await admin.rpc(
    "lookup_employee_portal_token_by_hash",
    { p_token_hash_hex: hashHex },
  );
  if (tokenError) {
    throw new AccessEmailError("token_lookup_failed", 500, tokenError.message);
  }
  const token = tokenData as TokenLookupRow | null;
  if (!token || token.token_id !== input.token_id) {
    throw new AccessEmailError("secret_token_mismatch", 403);
  }
  if (token.employee_id !== input.employee_id || token.tenant_id !== input.tenant_id) {
    throw new AccessEmailError("token_employee_mismatch", 403);
  }
  if (!token.is_active || token.revoked_at) {
    throw new AccessEmailError("token_revoked", 400);
  }
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) {
    throw new AccessEmailError("token_expired", 400);
  }

  const { data: employee, error: employeeError } = await admin
    .from("employees")
    .select("id, tenant_id, site_id, full_name, email")
    .eq("id", input.employee_id)
    .single();

  if (employeeError || !employee) {
    throw new AccessEmailError("employee_not_found", 404);
  }
  const employeeRow = employee as EmployeeRow;

  const { data: resolvedSite, error: siteError } = await admin.rpc(
    "resolve_public_site_for_employee",
    { p_employee_id: input.employee_id },
  );
  if (siteError) {
    throw new AccessEmailError("public_site_resolve_failed", 400, siteError.message);
  }
  const resolved = resolvedSite as ResolvedPublicSite;
  const portalUrl = buildPortalBootstrapUrl(resolved, secret);

  const { data: tenant, error: tenantError } = await admin
    .from("tenants")
    .select("name")
    .eq("id", input.tenant_id)
    .single();
  if (tenantError || !tenant) {
    throw new AccessEmailError("tenant_not_found", 404);
  }
  const tenantRow = tenant as TenantRow;

  let supportEmail = "";
  if (employeeRow.site_id) {
    const { data: site } = await admin
      .from("sites")
      .select("email_reply_to")
      .eq("id", employeeRow.site_id)
      .maybeSingle();
    supportEmail = (site as SiteRow | null)?.email_reply_to?.trim() ?? "";
  }

  const qrBytes = await generateQrPng(portalUrl);
  const storagePath =
    `${input.tenant_id}/employee-portal/${input.token_id}/${crypto.randomUUID()}.png`;

  const { error: uploadError } = await admin.storage
    .from(EMAIL_ATTACHMENTS_BUCKET)
    .upload(storagePath, qrBytes, {
      contentType: "image/png",
      upsert: false,
    });
  if (uploadError) {
    throw new AccessEmailError("qr_upload_failed", 500, uploadError.message);
  }

  const attachments: EmailAttachmentRef[] = [{
    filename: "portal-qr.png",
    storage_path: storagePath,
    content_type: "image/png",
    content_id: PORTAL_QR_CONTENT_ID,
  }];

  const expiresAtFormatted = token.expires_at
    ? new Date(token.expires_at).toLocaleDateString(
      locale === "en" ? "en-GB" : locale === "es" ? "es-ES" : "ca-ES",
    )
    : "";

  const idempotencyKey = `employee-portal-access:${input.token_id}:${crypto.randomUUID()}`;
  const { data: emailLogId, error: enqueueError } = await admin.rpc("enqueue_email", {
    payload: {
      tenant_id: input.tenant_id,
      site_id: employeeRow.site_id,
      idempotency_key: idempotencyKey,
      to: [recipient],
      event_type: input.template_id ? undefined : "employee_portal.access_link",
      template_id: input.template_id ?? undefined,
      template_variables: {
        employee_name: employeeRow.full_name,
        employee_first_name: firstName(employeeRow.full_name),
        portal_url: portalUrl,
        link_type: "personal",
        pin_instructions: pinInstructions(token, locale),
        tenant_name: tenantRow.name,
        site_name: resolved.site_name ?? "",
        support_email: supportEmail,
        expires_at: expiresAtFormatted,
      },
      attachments,
      locale,
      metadata: {
        employee_id: input.employee_id,
        token_id: input.token_id,
        recipient_override: input.recipient_override,
        requested_by_user_id: input.requested_by_user_id,
        link_type: "personal",
        portal_url: portalUrl,
        qr_storage_path: storagePath,
      },
      tags: ["employee_portal", "access_link"],
    },
  });

  if (enqueueError || !emailLogId) {
    await admin.storage.from(EMAIL_ATTACHMENTS_BUCKET).remove([storagePath]).catch(() => undefined);
    throw new AccessEmailError("enqueue_failed", 500, enqueueError?.message);
  }

  return {
    email_log_id: emailLogId as string,
    portal_url: portalUrl,
  };
}
