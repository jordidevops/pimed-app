/**
 * Best-effort cancel of superseded commercial DocuSeal submissions (F8 B7/B9).
 */
import { createAdminClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";
import { createOperationLogService } from "./observability/operation-log-service.ts";

const FEATURE = "docuseal-cancel-superseded";
const DOCUSEAL_API_KEY = Deno.env.get("DOCUSEAL_API_KEY") ?? "";
const DOCUSEAL_API_URL = Deno.env.get("DOCUSEAL_API_URL") ?? "https://api.docuseal.eu";

type AdminClient = ReturnType<typeof createAdminClient>;

async function resolvePlatformOrTenantKey(
  adminClient: AdminClient,
  tenantId: string,
): Promise<{ apiKey: string; apiUrl: string } | null> {
  const { data: cfg } = await adminClient
    .from("tenant_signing_status")
    .select("mode, docuseal_api_url")
    .eq("tenant_id", tenantId)
    .maybeSingle();

  const apiUrl =
    (cfg?.docuseal_api_url as string | null) ?? DOCUSEAL_API_URL;

  if (cfg?.mode === "platform" || !cfg) {
    if (!DOCUSEAL_API_KEY) return null;
    return { apiKey: DOCUSEAL_API_KEY, apiUrl };
  }

  // BYO: use get_docuseal_key_for_signing if available via admin RPC
  const { data: keyRow, error } = await adminClient.rpc(
    "get_docuseal_key_for_signing",
    { p_tenant_id: tenantId },
  );
  if (error || typeof keyRow !== "string" || !keyRow) {
    return DOCUSEAL_API_KEY
      ? { apiKey: DOCUSEAL_API_KEY, apiUrl }
      : null;
  }
  return { apiKey: keyRow, apiUrl };
}

export async function cancelSupersededCommercialDocuseal(params: {
  adminClient: AdminClient;
  requestId: string;
}): Promise<void> {
  const { adminClient, requestId } = params;
  const { data: rowsRaw, error } = await adminClient.rpc(
    "list_superseded_commercial_bridge_submissions",
    { p_request_id: requestId },
  );
  if (error || !Array.isArray(rowsRaw) || rowsRaw.length === 0) {
    return;
  }

  for (const row of rowsRaw as Array<Record<string, unknown>>) {
    const submissionId =
      typeof row.submission_id === "string" ? row.submission_id : null;
    const tenantId = typeof row.tenant_id === "string" ? row.tenant_id : null;
    const docusealId = row.docuseal_submission_id;
    if (!submissionId || !tenantId || docusealId == null) continue;

    try {
      await adminClient.rpc("mark_commercial_bridge_docuseal_cancel_attempted", {
        p_submission_id: submissionId,
      });

      const creds = await resolvePlatformOrTenantKey(adminClient, tenantId);
      if (!creds) {
        log("warn", FEATURE, "no DocuSeal key for cancel", {
          tenantId,
          correlationId: submissionId,
        });
        continue;
      }

      const res = await fetch(
        `${creds.apiUrl}/submissions/${docusealId}`,
        {
          method: "DELETE",
          headers: {
            "X-Auth-Token": creds.apiKey,
            Accept: "application/json",
          },
        },
      );

      if (!res.ok && res.status !== 404) {
        const text = await res.text().catch(() => "");
        log("warn", FEATURE, "DocuSeal cancel failed", {
          tenantId,
          correlationId: submissionId,
          extra: { status: res.status, body: text.slice(0, 200) },
        });
        const op = createOperationLogService(adminClient);
        await op.log({
          tenantId,
          integrationType: "signing",
          operationCode: "docuseal_cancel_superseded",
          status: "failed",
          title: "No s'ha pogut cancel·lar submission DocuSeal supersedida",
          message: `HTTP ${res.status}`,
          correlationId: submissionId,
          entityId: requestId,
          errorCode: "docuseal_cancel_failed",
        });
      } else {
        log("info", FEATURE, "DocuSeal cancel attempted", {
          tenantId,
          correlationId: submissionId,
          extra: { status: res.status },
        });
      }
    } catch (err) {
      log("warn", FEATURE, "DocuSeal cancel exception", {
        tenantId,
        correlationId: submissionId,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
    }
  }
}
