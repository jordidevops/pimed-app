import { captureMessage, initObservability } from "./system-error-tracker.ts";

export type LogLevel = "debug" | "info" | "warn" | "error";

export type StructuredLogFields = {
  tenantId?: string | null;
  userId?: string | null;
  correlationId?: string;
  durationMs?: number;
  integration?: string;
  extra?: Record<string, unknown>;
};

export function log(
  level: LogLevel,
  feature: string,
  msg: string,
  fields?: StructuredLogFields,
): void {
  console.log(JSON.stringify({
    level,
    feature,
    timestamp: new Date().toISOString(),
    msg,
    tenantId: fields?.tenantId ?? null,
    userId: fields?.userId ?? null,
    correlationId: fields?.correlationId ?? null,
    durationMs: fields?.durationMs,
    integration: fields?.integration,
    extra: fields?.extra,
  }));
}

export async function timedCall<T>(
  feature: string,
  integration: string,
  thresholdMs: number,
  fn: () => Promise<T>,
  onSlow?: (durationMs: number) => void,
): Promise<T> {
  const start = Date.now();
  try {
    return await fn();
  } finally {
    const durationMs = Date.now() - start;
    const level = durationMs > thresholdMs ? "warn" : "info";
    log(level, feature, `${integration} call completed`, {
      integration,
      durationMs,
      extra: durationMs > thresholdMs ? { threshold_exceeded: true, thresholdMs } : undefined,
    });
    if (durationMs > thresholdMs) {
      onSlow?.(durationMs);
    }
  }
}

export function defaultSlowHandler(
  feature: string,
  integration: string,
  thresholdMs: number,
): (durationMs: number) => void {
  return (durationMs) => {
    initObservability();
    captureMessage(`${integration} slow: ${durationMs}ms (threshold ${thresholdMs}ms)`, "warning", {
      feature,
      tags: { integration, slow: "true" },
      extra: { durationMs, thresholdMs },
    });
  };
}
