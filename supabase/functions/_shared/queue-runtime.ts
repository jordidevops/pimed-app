/**
 * @file queue-runtime.ts
 * @description Infraestructura genèrica per a workers PGMQ a Supabase Edge Functions.
 *
 * IMPORTANT: Aquest fitxer és 100% TypeScript estàndard.
 *   - Zero imports de Deno (Deno.env, Deno.serve, https://deno.land/..., npm:...).
 *   - Importable des d'Edge Functions (Deno) i des d'entorns Node.js/Jest.
 *   - El caller (Edge Function) és l'encarregat de crear el client admin i injectar-lo.
 *
 * Patró d'ús:
 *   import { QueueRunner } from "../_shared/queue-runtime.ts";
 *   const runner = new QueueRunner({ queueName: 'reminders_queue', handlers: {...}, db });
 *   const summary = await runner.runBatch();
 *
 * Tots els RPCs que crida internament (check_dedup, record_processed, move_to_dlq, etc.)
 * estan definits a la migració 20260503000002_async_infra.sql i són service_role only.
 */

import { log } from "./observability/structured-logger.ts";

const FEATURE = "queue-runtime";

// =============================================================================
// Types exportats
// =============================================================================

/**
 * Estructura estàndard del payload PGMQ per a totes les cues del projecte.
 * Les cues legacy (email_send_queue, trash_deletion_queue) poden tenir camps
 * addicionals en lloc del camp `task`; en aquest cas cal configurar `defaultTask`.
 */
export interface TaskPayload {
  /** Nom del handler a executar. Opcional si QueueRunnerConfig.defaultTask està configurat. */
  task?: string;
  /** UUID del tenant. OBLIGATORI per a l'aïllament multi-tenant. */
  tenant_id: string;
  /** Clau per a dedup idempotent. Hauria de ser determinista (ex: 'rem-<event_id>-60'). */
  idempotency_key: string;
  site_id?: string | null;
  actor_user_id?: string | null;
  entity_type?: string;
  entity_id?: string;
  enqueued_at?: string;
  /** Dades específiques de la tasca (patró estàndard). */
  payload?: Record<string, unknown>;
  /** Permet camps addicionals per compatibilitat amb cues legacy. */
  [key: string]: unknown;
}

/** Missatge llegit de PGMQ via api.read_queue_batch. */
export interface QueueMessage {
  msg_id: number;
  /** Número de vegades que el missatge ha estat llegit (attempt count). */
  read_ct: number;
  message: TaskPayload;
}

/** Resultat que retorna un TaskHandler. */
export interface TaskResult {
  success: boolean;
  /**
   * Si true, el QueueRunner NO aplica retry/DLQ genèric:
   *   - Útil per a cues que gestionen els seus propis retries (ex: email_send_queue).
   *   - El missatge queda a la cua; el VT expirarà i serà reprocessat naturalment.
   *   - Usar quan la fallada és temporal i el handler ja ha actualitzat l'estat intern.
   */
  selfManaged?: boolean;
}

/**
 * Context que rep el handler en executar-se.
 * Proporciona accés al client admin i informació del missatge actual.
 */
export interface WorkerContext {
  /** Client admin Supabase (service_role, bypassa RLS). */
  db: AdminClient;
  queueName: string;
  msgId: number;
  /** Número d'intents previs (llegit de PGMQ read_ct). */
  readCount: number;
}

export type TaskHandler = (
  payload: TaskPayload,
  ctx: WorkerContext,
) => Promise<TaskResult>;

export type PreprocessBatch = (
  messages: QueueMessage[],
  ctx: { db: AdminClient; queueName: string },
) => Promise<QueueMessage[]>;

export interface QueueRunnerConfig {
  queueName: string;
  handlers: Record<string, TaskHandler>;
  db: AdminClient;
  /**
   * Task name per defecte quan payload.task és absent.
   * Útil per a cues legacy (email_send_queue, trash_deletion_queue) que no
   * inclouen el camp `task` al payload.
   */
  defaultTask?: string;
  /** Nombre màxim d'intents abans de moure a DLQ. Default: 3. */
  maxAttempts?: number;
  /** Missatges a llegir per invocació (batch). Default: 10. Max: 50 (límit pgmq). */
  batchSize?: number;
  /**
   * Visibility Timeout inicial en segons (temps que el missatge és invisible
   * mentre es processa). Default: 60.
   * Per a tasques llargues o cues legacy (email, deletion): usar 300.
   */
  visibilityTimeoutSec?: number;
  /**
   * Hook opcional abans de processar el batch (fairness, reordenació).
   * No ha d'arxivar missatges ni escriure dedup — només filtrar/reordenar
   * o retornar excedents via set_queue_message_vt des del hook.
   */
  preprocessBatch?: PreprocessBatch;
}

export interface BatchSummary {
  queueName: string;
  total: number;
  succeeded: number;
  skipped: number;
  retried: number;
  dlqed: number;
  errors: string[];
}

/**
 * Interfície mínima del client admin Supabase.
 * Compatible amb SupabaseClient<Database, "api"> de @supabase/supabase-js v2.
 * Definida com any per evitar dependre de l'import de supabase-js en aquest fitxer.
 * El caller (Edge Function) injecta el client tipat correctament.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AdminClient = any;


// =============================================================================
// QueueRunner
// =============================================================================

export class QueueRunner {
  private readonly queueName: string;
  private readonly handlers: Record<string, TaskHandler>;
  private readonly db: AdminClient;
  private readonly defaultTask: string | undefined;
  private readonly maxAttempts: number;
  private readonly batchSize: number;
  private readonly vt: number;
  private readonly preprocessBatch?: PreprocessBatch;

  constructor(cfg: QueueRunnerConfig) {
    this.queueName = cfg.queueName;
    this.handlers = cfg.handlers;
    this.db = cfg.db;
    this.defaultTask = cfg.defaultTask;
    this.maxAttempts = cfg.maxAttempts ?? 3;
    this.batchSize = cfg.batchSize ?? 10;
    this.vt = cfg.visibilityTimeoutSec ?? 60;
    this.preprocessBatch = cfg.preprocessBatch;
  }

  /** Llegeix un batch, processa cada missatge i retorna un resum del cicle. */
  async runBatch(): Promise<BatchSummary> {
    const summary: BatchSummary = {
      queueName: this.queueName,
      total: 0,
      succeeded: 0,
      skipped: 0,
      retried: 0,
      dlqed: 0,
      errors: [],
    };

    // 1. Llegir batch (+ preprocess opcional)
    let messages = await this.readBatch();
    if (this.preprocessBatch && messages.length > 0) {
      messages = await this.preprocessBatch(messages, {
        db: this.db,
        queueName: this.queueName,
      });
    }
    summary.total = messages.length;

    if (messages.length === 0) return summary;

    // 2. Processar cada missatge de forma independent (fallada aïllada)
    for (const msg of messages) {
      try {
        await this.processMessage(msg, summary);
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        summary.errors.push(`msg ${msg.msg_id}: ${errMsg}`);
        log("error", FEATURE, "Unexpected top-level error processing message", {
          integration: this.queueName,
          extra: { msg_id: msg.msg_id, error: errMsg },
        });
      }
    }

    // 3. Audit del batch (fire-and-forget: no ha de trencar el worker)
    this.logBatchAudit(summary).catch((err) => {
      log("warn", FEATURE, "Batch audit failed", {
        integration: this.queueName,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
    });

    return summary;
  }

  // ─── Mètodes privats ──────────────────────────────────────────────────────

  private async readBatch(): Promise<QueueMessage[]> {
    const { data, error } = await this.db.rpc("read_queue_batch", {
      p_queue: this.queueName,
      p_count: this.batchSize,
      p_vt: this.vt,
    });

    if (error) {
      throw new Error(`[QueueRunner:${this.queueName}] read_queue_batch RPC failed: ${error.message}`);
    }

    return (data as QueueMessage[]) ?? [];
  }

  private async processMessage(
    msg: QueueMessage,
    summary: BatchSummary,
  ): Promise<void> {
    const { msg_id, read_ct, message: payload } = msg;

    // Validació: tenant_id obligatori per aïllament multi-tenant
    if (!payload?.tenant_id) {
      log("warn", FEATURE, "Missing tenant_id — routing to DLQ", {
        integration: this.queueName,
        extra: { msg_id },
      });
      await this.moveToDlq(msg, "TENANT_INVALID: payload.tenant_id is missing or null");
      await this.archiveMessage(msg_id);
      summary.dlqed++;
      return;
    }

    // Idempotency key (fallback al msg_id si el payload no el porta)
    const idempotencyKey =
      typeof payload.idempotency_key === "string" && payload.idempotency_key
        ? payload.idempotency_key
        : `${this.queueName}:${msg_id}`;

    // Dedup check
    const isDuplicate = await this.dedupCheck(idempotencyKey);
    if (isDuplicate) {
      log("info", FEATURE, "Duplicate idempotency key — skipping", {
        integration: this.queueName,
        extra: { msg_id, idempotency_key: idempotencyKey },
      });
      await this.archiveMessage(msg_id);
      summary.skipped++;
      return;
    }

    // Resolució del handler
    const taskName = (typeof payload.task === "string" ? payload.task : undefined) ?? this.defaultTask;
    if (!taskName) {
      await this.moveToDlq(msg, `UNKNOWN_TASK: payload.task is missing and no defaultTask configured`);
      await this.archiveMessage(msg_id);
      summary.dlqed++;
      return;
    }

    const handler = this.handlers[taskName];
    if (!handler) {
      await this.moveToDlq(msg, `UNKNOWN_TASK: no handler registered for task '${taskName}'`);
      await this.archiveMessage(msg_id);
      summary.dlqed++;
      return;
    }

    // Executar handler
    const ctx: WorkerContext = {
      db: this.db,
      queueName: this.queueName,
      msgId: msg_id,
      readCount: read_ct,
    };

    let result: TaskResult;
    try {
      result = await handler(payload, ctx);
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      log("error", FEATURE, "Handler threw unexpected error", {
        integration: this.queueName,
        extra: { msg_id, task: taskName, error: errMsg },
      });
      // Aplicar retry / DLQ genèric
      if (read_ct >= this.maxAttempts) {
        await this.moveToDlq(msg, errMsg);
        await this.archiveMessage(msg_id);
        summary.dlqed++;
      } else {
        await this.retryWithBackoff(msg_id, read_ct);
        summary.retried++;
      }
      return;
    }

    if (result.success) {
      // Èxit: dedup + archive
      await this.recordProcessed(idempotencyKey, msg_id);
      await this.archiveMessage(msg_id);
      summary.succeeded++;
    } else if (result.selfManaged) {
      // El handler gestiona el seu propi retry (ex: email_send_queue amb state machine)
      // El missatge queda a la cua; el VT expirarà i serà reprocessat.
      summary.retried++;
    } else {
      // Fallada genèrica: retry exponencial o DLQ
      if (read_ct >= this.maxAttempts) {
        await this.moveToDlq(msg, `Handler '${taskName}' returned { success: false } after ${read_ct} attempts`);
        await this.archiveMessage(msg_id);
        summary.dlqed++;
      } else {
        await this.retryWithBackoff(msg_id, read_ct);
        summary.retried++;
      }
    }
  }

  /** Comprova si idempotency_key ja existeix a data.processed_messages. */
  private async dedupCheck(idempotencyKey: string): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_dedup", {
      p_queue: this.queueName,
      p_key: idempotencyKey,
    });
    if (error) {
      log("warn", FEATURE, "dedupCheck error", {
        integration: this.queueName,
        extra: { error: error.message },
      });
      // En cas d'error de dedup, deixem passar (els handlers han de ser idempotents)
      return false;
    }
    return data === true;
  }

  /** Registra un missatge com a processat per a dedup futures. */
  private async recordProcessed(idempotencyKey: string, msgId: number): Promise<void> {
    const { error } = await this.db.rpc("record_processed", {
      p_queue: this.queueName,
      p_msg_id: msgId,
      p_key: idempotencyKey,
    });
    if (error) {
      // Non-fatal: si falla el dedup record, el handler tornarà a executar-se
      // (idempotent per disseny). Únicament loguem.
      log("warn", FEATURE, "recordProcessed error", {
        integration: this.queueName,
        extra: { error: error.message },
      });
    }
  }

  /** Arxiva un missatge de la cua (acknowledge). */
  private async archiveMessage(msgId: number): Promise<void> {
    const { error } = await this.db.rpc("archive_queue_message", {
      p_queue: this.queueName,
      p_msg_id: msgId,
    });
    if (error) {
      // Si archive falla, el missatge tornarà a ser visible quan expiri el VT.
      // Serà un duplicat que el dedup check filtrarà en el proper intent.
      log("warn", FEATURE, "archiveMessage error", {
        integration: this.queueName,
        extra: { msg_id: msgId, error: error.message },
      });
    }
  }

  /**
   * Amplia el VT del missatge amb backoff exponencial:
   *   attempt=0 → 60s, attempt=1 → 120s, attempt=2 → 240s (màx 3600s = 1h).
   */
  private async retryWithBackoff(msgId: number, attempt: number): Promise<void> {
    const vtSeconds = Math.min(60 * Math.pow(2, attempt), 3600);
    const { error } = await this.db.rpc("set_queue_message_vt", {
      p_queue: this.queueName,
      p_msg_id: msgId,
      p_vt_seconds: Math.round(vtSeconds),
    });
    if (error) {
      log("warn", FEATURE, "retryWithBackoff error", {
        integration: this.queueName,
        extra: { msg_id: msgId, error: error.message },
      });
    }
  }

  /**
   * Mou el missatge al Dead Letter Queue via api.move_to_dlq:
   *   - Insereix a data.dlq_messages
   *   - Notifica owners del tenant (severity='critical')
   *   - Escriu a data.audit_logs (TASK_DLQ_MOVED)
   */
  private async moveToDlq(msg: QueueMessage, errorText: string): Promise<void> {
    const { error } = await this.db.rpc("move_to_dlq", {
      p_queue: this.queueName,
      p_original_msg_id: msg.msg_id,
      p_payload: msg.message,
      p_attempt_count: msg.read_ct,
      p_error: errorText.slice(0, 2048),
    });
    if (error) {
      log("error", FEATURE, "move_to_dlq error", {
        integration: this.queueName,
        extra: { msg_id: msg.msg_id, error: error.message },
      });
    }
  }

  /** Escriu el resum del batch a data.audit_logs (fire-and-forget). */
  private async logBatchAudit(summary: BatchSummary): Promise<void> {
    await this.db.rpc("log_queue_batch_audit", {
      p_queue_name: this.queueName,
      p_total:      summary.total,
      p_succeeded:  summary.succeeded,
      p_skipped:    summary.skipped,
      p_retried:    summary.retried,
      p_dlqed:      summary.dlqed,
    });
  }
}
