import * as Sentry from "npm:@sentry/deno@8";
import type { ErrorContext, MessageLevel, SystemErrorTracker } from "../context.ts";
import { createConsoleAdapter } from "./console-adapter.ts";

const SECRET_PATTERNS = [
  /Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi,
  /sk-[A-Za-z0-9]+/gi,
  /eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+/g,
];

function sanitizeExtras(extra?: Record<string, unknown>): Record<string, unknown> | undefined {
  if (!extra) return undefined;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(extra)) {
    if (typeof value === "string") {
      let sanitized = value;
      for (const pattern of SECRET_PATTERNS) {
        sanitized = sanitized.replace(pattern, "[REDACTED]");
      }
      out[key] = sanitized.slice(0, 500);
    } else {
      out[key] = value;
    }
  }
  return out;
}

function applyScope(scope: Sentry.Scope, ctx: ErrorContext): void {
  if (ctx.tenantId) scope.setTag("tenant_id", ctx.tenantId);
  if (ctx.userId) scope.setUser({ id: ctx.userId });
  if (ctx.correlationId) scope.setTag("correlation_id", ctx.correlationId);
  scope.setTag("feature", ctx.feature);
  for (const [key, value] of Object.entries(ctx.tags ?? {})) {
    scope.setTag(key, value);
  }
  const extras = sanitizeExtras(ctx.extra);
  if (extras) scope.setExtras(extras);
}

let sentryInitialized = false;

function ensureSentryInit(dsn: string, environment: string): void {
  if (sentryInitialized) return;
  Sentry.init({
    dsn,
    environment,
    tracesSampleRate: 0.1,
    beforeSend(event) {
      if (event.environment === "local") return null;
      return event;
    },
  });
  sentryInitialized = true;
}

export function createSentryAdapter(): SystemErrorTracker {
  const dsn = Deno.env.get("SENTRY_DSN");
  const env = Deno.env.get("ENVIRONMENT") ?? "local";

  if (!dsn || env === "local") {
    return createConsoleAdapter();
  }

  ensureSentryInit(dsn, env);

  return {
    captureException(error, ctx) {
      Sentry.withScope((scope) => {
        applyScope(scope, ctx);
        Sentry.captureException(error);
      });
    },
    captureMessage(message, level, ctx) {
      Sentry.withScope((scope) => {
        applyScope(scope, ctx);
        Sentry.captureMessage(message, level);
      });
    },
  };
}
