import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import {
  applyLineOverrides,
  hashLines,
  run,
  type Definition,
  type LineOverrides,
  type OutputLine,
  type ParamValues,
} from "../_shared/price-calculator/mod.ts";

const FEATURE = "apply-calculator-run";

type Body = {
  version_id: string;
  params: ParamValues;
  lines_hash: string;
  client_op_id: string;
  project_id?: string | null;
  document_id?: string | null;
  line_overrides?: LineOverrides;
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, error: string, message: string): Response {
  return jsonResponse({ error, message }, status);
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const tenantId = req.headers.get("x-tenant-id");
    if (!tenantId) {
      return errorResponse(400, "missing_tenant", "Cal enviar l'header x-tenant-id");
    }

    const userClient = createUserClient(req);
    const { data: authData, error: authError } = await userClient.auth.getUser();
    const user = authData.user;
    if (authError || !user) {
      return errorResponse(401, "unauthorized", "No autenticat");
    }

    const raw = await req.json() as Body;
    if (!raw?.version_id || !raw?.client_op_id || !raw?.lines_hash) {
      return errorResponse(400, "invalid_body", "Falten version_id, client_op_id o lines_hash");
    }
    const hasProject = !!raw.project_id;
    const hasDocument = !!raw.document_id;
    if (hasProject === hasDocument) {
      return errorResponse(400, "destination_xor", "Cal project_id o document_id, no tots dos");
    }

    const { data: versionRow, error: versionError } = await userClient
      .from("calculator_versions" as never)
      .select("id, definition_id, definition, tenant_id")
      .eq("id", raw.version_id)
      .maybeSingle();

    if (versionError || !versionRow) {
      return errorResponse(404, "calculator_version_not_found", "Versió no trobada");
    }

    const row = versionRow as {
      id: string
      definition_id: string
      definition: Definition
      tenant_id: string
    };

    if (row.tenant_id !== tenantId) {
      return errorResponse(403, "forbidden", "Tenant incorrecte");
    }

    const result = run(row.definition, raw.params ?? {}, "ca");
    if (result.errors.length) {
      return jsonResponse(
        { error: "calculator_run_failed", errors: result.errors },
        422,
      );
    }

    const overridden = applyLineOverrides(
      result.lines as OutputLine[],
      raw.line_overrides,
      row.definition,
    );
    if (overridden.errors.length) {
      return jsonResponse(
        { error: "calculator_override_failed", errors: overridden.errors },
        422,
      );
    }

    const serverHash = await hashLines(overridden.lines);
    if (serverHash !== raw.lines_hash) {
      log("warn", FEATURE, "parity_mismatch", {
        client_hash: raw.lines_hash,
        server_hash: serverHash,
      });
      return errorResponse(
        409,
        "calculator_parity_mismatch",
        "El resultat del portal no coincideix amb el del servidor",
      );
    }

    const admin = createAdminClient();
    const { data: applyResult, error: applyError } = await admin.rpc(
      "apply_calculator_lines" as never,
      {
        p_version_id: raw.version_id,
        p_params: raw.params ?? {},
        p_lines: overridden.lines,
        p_lines_hash: serverHash,
        p_client_op_id: raw.client_op_id,
        p_actor_user_id: user.id,
        p_project_id: raw.project_id ?? null,
        p_document_id: raw.document_id ?? null,
      } as never,
    );

    if (applyError) {
      const msg = applyError.message ?? "apply_failed";
      const status = msg.includes("forbidden") ? 403 : 400;
      return errorResponse(status, "apply_failed", msg);
    }

    return jsonResponse({
      ok: true,
      lines: overridden.lines,
      lines_hash: serverHash,
      result: applyResult,
    });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    log("error", FEATURE, "unhandled", {
      message: err instanceof Error ? err.message : String(err),
    });
    return errorResponse(500, "internal_error", "Error intern");
  }
});
