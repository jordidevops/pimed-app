import type { ErrorContext, MessageLevel, SystemErrorTracker } from "../context.ts";

function writeStructured(level: MessageLevel, payload: Record<string, unknown>): void {
  console.log(JSON.stringify({ level, timestamp: new Date().toISOString(), ...payload }));
}

export function createConsoleAdapter(): SystemErrorTracker {
  return {
    captureException(error, ctx) {
      writeStructured("error", {
        type: "exception",
        feature: ctx.feature,
        tenantId: ctx.tenantId ?? null,
        userId: ctx.userId ?? null,
        correlationId: ctx.correlationId ?? null,
        message: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : undefined,
        tags: ctx.tags ?? {},
        extra: ctx.extra ?? {},
      });
    },
    captureMessage(message, level, ctx) {
      writeStructured(level, {
        type: "message",
        feature: ctx.feature,
        tenantId: ctx.tenantId ?? null,
        userId: ctx.userId ?? null,
        correlationId: ctx.correlationId ?? null,
        message,
        tags: ctx.tags ?? {},
        extra: ctx.extra ?? {},
      });
    },
  };
}
