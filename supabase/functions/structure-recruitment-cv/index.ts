import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { extractPdfAllText } from "../_shared/ai/pdf-processor.ts";
import { runAiGeneration } from "../_shared/ai/run.ts";
import { AiRateLimitError, AiUserBlockedError } from "../_shared/ai/usage.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "structure-recruitment-cv";
const AI_FEATURE = "recruitment_cv_structure";
const MIN_TEXT_CHARS = 40;
const MAX_TEXT_CHARS = 24_000;

const SYSTEM_PROMPT = `Ets un assistent de reclutament. A partir del text d'un CV, proposa una estructuració en JSON.
Respon NOMÉS amb un objecte JSON vàlid amb aquesta forma exacta:
{
  "skills": ["string"],
  "experience": [{"title":"string","company":"string","period":"string","summary":"string"}],
  "education": [{"degree":"string","institution":"string","period":"string"}],
  "languages": [{"name":"string","level":"string"}]
}
Regles:
- No inventis dades que no apareguin al text.
- Si un camp no es pot inferir, usa array buit o omet el camp intern.
- No incloguis fotos, dates de naixement ni NIF/DNI encara que surtin al text.
- La proposta és assistiva: un humà la revisarà (Art. 22).`;

type GateResult = {
  ok: boolean;
  application_id: string;
  tenant_id: string;
  cv_storage_path: string;
  ai_checklist_version: string | null;
};

function parseProposal(content: string): Record<string, unknown> {
  const trimmed = content.trim();
  const tryParse = (raw: string): Record<string, unknown> | null => {
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      // ignore
    }
    return null;
  };

  const direct = tryParse(trimmed);
  if (direct) return direct;

  const fence = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence?.[1]) {
    const fenced = tryParse(fence[1].trim());
    if (fenced) return fenced;
  }

  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) {
    const sliced = tryParse(trimmed.slice(start, end + 1));
    if (sliced) return sliced;
  }

  throw new Error("No s'ha pogut interpretar la resposta JSON del model");
}

function normalizeProposal(raw: Record<string, unknown>): {
  skills: string[];
  experience: unknown[];
  education: unknown[];
  languages: unknown[];
} {
  const skills: string[] = [];
  if (Array.isArray(raw.skills)) {
    for (const s of raw.skills) {
      if (typeof s === "string" && s.trim()) skills.push(s.trim());
      else if (s && typeof s === "object" && typeof (s as { name?: string }).name === "string") {
        const n = (s as { name: string }).name.trim();
        if (n) skills.push(n);
      }
    }
  }
  return {
    skills,
    experience: Array.isArray(raw.experience) ? raw.experience : [],
    education: Array.isArray(raw.education) ? raw.education : [],
    languages: Array.isArray(raw.languages) ? raw.languages : [],
  };
}

Deno.serve(async (req: Request) => {
  initObservability();
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const tenantId = requireTenantHeader(req);
    const userClient = createUserClient(req);
    const user = await requireAuthenticatedUser(userClient);
    await assertTenantMember(userClient, tenantId, user.id);

    const body = (await req.json().catch(() => ({}))) as { application_id?: string };
    const applicationId = body.application_id?.trim();
    if (!applicationId) {
      return errorResponse(400, "invalid_application_id", "application_id és obligatori");
    }

    const { data: gateRaw, error: gateErr } = await userClient.rpc(
      "get_recruitment_cv_structure_gate",
      { p_application_id: applicationId },
    );
    if (gateErr) {
      const msg = gateErr.message ?? "gate_failed";
      if (msg.includes("module_not_enabled")) {
        return errorResponse(403, "module_not_enabled", "Mòdul de reclutament no actiu");
      }
      if (msg.includes("ai_assist_disabled") || msg.includes("checklist")) {
        return errorResponse(403, "ai_assist_disabled", "IA en reclutament no activada o checklist incompleta");
      }
      if (msg.includes("ai_not_configured")) {
        return errorResponse(403, "ai_not_configured", "Cal configurar la IA del tenant");
      }
      if (msg.includes("no_cv")) {
        return errorResponse(400, "no_cv", "La candidatura no té CV");
      }
      if (msg.includes("not_found")) {
        return errorResponse(404, "not_found", "Candidatura no trobada");
      }
      if (msg.includes("forbidden") || gateErr.code === "42501") {
        return errorResponse(403, "forbidden", "Sense permís recruitment.manage");
      }
      return errorResponse(400, "gate_failed", msg);
    }

    const gate = gateRaw as GateResult;
    if (gate.tenant_id && gate.tenant_id !== tenantId) {
      return errorResponse(403, "tenant_mismatch", "Tenant de la candidatura no coincideix");
    }
    const path = gate.cv_storage_path;
    if (!path || typeof path !== "string") {
      return errorResponse(400, "no_cv", "La candidatura no té CV");
    }
    if (!path.toLowerCase().endsWith(".pdf")) {
      return jsonResponse({
        status: "needs_human_review",
        reason: "not_pdf",
        application_id: applicationId,
      });
    }

    const adminClient = createAdminClient();
    const { data: fileBlob, error: downErr } = await adminClient.storage
      .from("recruitment-cvs")
      .download(path);

    if (downErr || !fileBlob) {
      log("error", FEATURE, "CV download failed", {
        tenantId,
        extra: { path, error: downErr?.message },
      });
      return errorResponse(500, "download_failed", "No s'ha pogut descarregar el CV");
    }

    const bytes = new Uint8Array(await fileBlob.arrayBuffer());
    const extracted = await extractPdfAllText(bytes);
    const text = extracted.slice(0, MAX_TEXT_CHARS).trim();

    if (text.length < MIN_TEXT_CHARS) {
      return jsonResponse({
        status: "needs_human_review",
        reason: "no_text_layer",
        application_id: applicationId,
        chars_extracted: text.length,
      });
    }

    const result = await runAiGeneration({
      adminClient,
      tenantId,
      userId: user.id,
      body: {
        feature: AI_FEATURE,
        responseFormat: "json",
        temperature: 0.1,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          {
            role: "user",
            content:
              `Estructura aquest CV (només text; no hi ha imatge):\n\n---\n${text}\n---`,
          },
        ],
      },
    });

    const proposal = normalizeProposal(parseProposal(result.content));

    return jsonResponse({
      status: "proposal",
      application_id: applicationId,
      proposal,
      provider: result.provider,
      model: result.model,
      feature: AI_FEATURE,
      chars_sent: text.length,
      warnings: result.warnings ?? null,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    if (err instanceof AiRateLimitError) {
      return errorResponse(429, "rate_limit_exceeded", err.message);
    }
    if (err instanceof AiUserBlockedError) {
      return errorResponse(403, "user_blocked", err.message);
    }
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "structure CV failed", {
      tenantId: req.headers.get("x-tenant-id") ?? undefined,
      extra: { error: message },
    });
    captureException(err, {
      feature: FEATURE,
      tenantId: req.headers.get("x-tenant-id"),
    });
    return errorResponse(500, "structure_failed", message);
  }
});
