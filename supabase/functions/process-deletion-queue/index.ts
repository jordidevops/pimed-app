/**
 * process-deletion-queue — Refactored with QueueRunner
 *
 * Llegeix missatges de 'trash_deletion_queue', elimina físicament els fitxers
 * de Supabase Storage o BYOS (S3/R2/GCS) i arxiva el missatge.
 *
 * Canvis respecte la versió anterior:
 *   - Usa QueueRunner per al bucle batch, dedup, retry exponencial i DLQ.
 *   - Usa api.read_queue_batch + api.archive_queue_message (genèriques).
 *   - Manté el contracte de payload: { file_node_id, tenant_id, storage_provider_id, storage_key }.
 *   - VT = 300s (igual que abans) per a tasques d'esborrat que poden tardar.
 *   - maxAttempts = 3 → DLQ automàtic + notificació owners (millora vs. retry infinit anterior).
 *
 * Smoke test local:
 *   curl -X POST http://127.0.0.1:54321/functions/v1/process-deletion-queue \
 *     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" -H "Content-Type: application/json" -d "{}"
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
} from "../_shared/queue-runtime.ts";
import { DeleteObjectCommand, S3Client } from "npm:@aws-sdk/client-s3";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log, timedCall, defaultSlowHandler } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-deletion-queue";
const DELETE_SLOW_MS = 10_000;

// ---------------------------------------------------------------------------
// Types (payload d'aquesta cua específica)
// ---------------------------------------------------------------------------

interface DeletionPayload extends TaskPayload {
  file_node_id: string;
  storage_provider_id: string | null;
  /** Null per a nodes carpeta (no hi ha objecte físic associat) */
  storage_key: string | null;
  /**
   * Bucket de Supabase Storage on viu el fitxer.
   * Per defecte: DEFAULT_BUCKET ('tenant-files').
   * Els documents DMS usen 'documents'.
   */
  bucket?: string | null;
}

interface StorageProvider {
  id: string;
  provider_type: string;
  endpoint_url: string | null;
  bucket_name: string;
  access_key: string;
  secret_key: string;
  region: string | null;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const QUEUE_NAME = "trash_deletion_queue";
/** Missatges a llegir per invocació */
const DEFAULT_BATCH_SIZE = 10;
/** Default Supabase Storage bucket per a tenants sense BYOS */
const DEFAULT_BUCKET = "tenant-files";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Physical deletion — BYOS (S3 / R2 / GCS)
// ---------------------------------------------------------------------------

/**
 * Elimina un objecte d'un bucket BYOS.
 * S3 DeleteObject és idempotent: retorna 204 fins i tot si l'objecte no existeix.
 */
async function deleteFromByos(
  provider: StorageProvider,
  storageKey: string,
): Promise<void> {
  const clientConfig: ConstructorParameters<typeof S3Client>[0] = {
    region: provider.region ?? "us-east-1",
    credentials: {
      accessKeyId: provider.access_key,
      secretAccessKey: provider.secret_key,
    },
  };

  if (provider.endpoint_url) {
    clientConfig.endpoint = provider.endpoint_url;
    clientConfig.forcePathStyle = provider.provider_type === "r2";
  }

  const s3 = new S3Client(clientConfig);
  await s3.send(
    new DeleteObjectCommand({ Bucket: provider.bucket_name, Key: storageKey }),
  );
}

// ---------------------------------------------------------------------------
// Physical deletion — Supabase Storage (default bucket)
// ---------------------------------------------------------------------------

/**
 * Elimina un objecte de Supabase Storage.
 * Tracta 200 i 404 com a èxit (idempotent).
 * @param bucket Bucket de destí. Default: DEFAULT_BUCKET ('tenant-files').
 */
async function deleteFromSupabaseStorage(
  storageKey: string,
  bucket: string = DEFAULT_BUCKET,
): Promise<void> {
  const url = `${SUPABASE_URL}/storage/v1/object/${bucket}/${storageKey}`;
  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` },
  });
  if (!response.ok && response.status !== 404) {
    const body = await response.text().catch(() => "");
    throw new Error(`Supabase Storage DELETE HTTP ${response.status}: ${body}`);
  }
}

// ---------------------------------------------------------------------------
// Cache de providers BYOS (per invocació — evita una RPC per missatge del mateix tenant)
// ---------------------------------------------------------------------------

const providerCache = new Map<string, StorageProvider | null>();

async function getProvider(
  db: WorkerContext["db"],
  tenantId: string,
): Promise<StorageProvider | null> {
  if (providerCache.has(tenantId)) return providerCache.get(tenantId)!;

  const { data: rows, error } = await db.rpc(
    "get_storage_provider_with_secret",
    { p_tenant_id: tenantId },
  );
  const provider =
    !error && rows && rows.length > 0 ? (rows[0] as StorageProvider) : null;

  if (error) {
    log("error", FEATURE, "get_storage_provider error", {
      tenantId,
      extra: { error: error.message },
    });
  }

  providerCache.set(tenantId, provider);
  return provider;
}

// ---------------------------------------------------------------------------
// TaskHandler: delete_storage_object
// ---------------------------------------------------------------------------

const deleteStorageObjectHandler: TaskHandler = async (
  rawPayload,
  ctx,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as DeletionPayload;
  const { file_node_id, tenant_id, storage_provider_id, storage_key } = msg;
  const operationLog = createOperationLogService(ctx.db);

  if (!storage_key) {
    log("info", FEATURE, "No storage_key — no-op", {
      tenantId: tenant_id,
      correlationId: file_node_id,
    });
    return { success: true };
  }

  try {
    if (storage_provider_id) {
      const provider = await getProvider(ctx.db, tenant_id);

      if (!provider) {
        log("warn", FEATURE, "BYOS provider gone — orphaned object", {
          tenantId: tenant_id,
          correlationId: file_node_id,
        });
        return { success: true };
      }

      await timedCall(
        FEATURE,
        "byos_delete",
        DELETE_SLOW_MS,
        () => deleteFromByos(provider, storage_key),
        defaultSlowHandler(FEATURE, "byos_delete", DELETE_SLOW_MS),
      );
    } else {
      const bucket = msg.bucket ?? DEFAULT_BUCKET;
      await timedCall(
        FEATURE,
        "supabase_storage_delete",
        DELETE_SLOW_MS,
        () => deleteFromSupabaseStorage(storage_key, bucket),
        defaultSlowHandler(FEATURE, "supabase_storage_delete", DELETE_SLOW_MS),
      );
    }

    return { success: true };
  } catch (err) {
    const errMsg = (err as Error).message;
    log("error", FEATURE, "Storage delete failed", {
      tenantId: tenant_id,
      correlationId: file_node_id,
      extra: { error: errMsg },
    });

    await operationLog.log({
      tenantId: tenant_id,
      integrationType: "storage",
      operationCode: "delete_trash_object",
      status: "failed",
      title: "No s'ha pogut eliminar el fitxer de la paperera",
      message: errMsg.slice(0, 200),
      errorCode: "delete_failed",
      errorMessage: errMsg,
      correlationId: file_node_id,
      entityType: "file_node",
      entityId: file_node_id,
      externalService: storage_provider_id ? "byos" : "supabase_storage",
      isRetryable: true,
      payloadSummary: { storage_key: storage_key.slice(0, 80) },
    });

    if (isInfrastructureBug(err)) {
      captureException(err, { feature: FEATURE, tenantId: tenant_id, correlationId: file_node_id });
    }

    throw err;
  }
};

// ---------------------------------------------------------------------------
// Edge Function entry point
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: { code: "method_not_allowed" } });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    log("error", FEATURE, "Unauthorized batch request");
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  // Netejar caché de providers per a cada invocació fresca
  providerCache.clear();

  let batchSize = DEFAULT_BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, 50));
    }
  } catch {
    // Body buit o no-JSON → usar default
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    defaultTask: "delete_storage_object",
    handlers: {
      delete_storage_object: deleteStorageObjectHandler,
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: 300,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return jsonResponse(200, summary);
  } catch (err) {
    log("error", FEATURE, "Unexpected batch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, {
      error: { code: "internal_error", message: "An unexpected error occurred" },
    });
  }
});
