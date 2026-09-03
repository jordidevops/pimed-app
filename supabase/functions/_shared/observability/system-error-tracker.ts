import type { ErrorContext, MessageLevel, SystemErrorTracker } from "./context.ts";
import { createConsoleAdapter } from "./adapters/console-adapter.ts";
import { createSentryAdapter } from "./adapters/sentry-adapter.ts";

let adapter: SystemErrorTracker | null = null;
let initialized = false;

function assertFeature(ctx: ErrorContext): void {
  if (!ctx.feature?.trim()) {
    throw new Error("ErrorContext.feature is required");
  }
}

function getAdapter(): SystemErrorTracker {
  if (!adapter) {
    adapter = createSentryAdapter();
  }
  return adapter;
}

export function initObservability(): void {
  if (initialized) return;
  adapter = createSentryAdapter();
  initialized = true;
}

export function captureException(error: unknown, ctx: ErrorContext): void {
  assertFeature(ctx);
  getAdapter().captureException(error, ctx);
}

export function captureMessage(message: string, level: MessageLevel, ctx: ErrorContext): void {
  assertFeature(ctx);
  getAdapter().captureMessage(message, level, ctx);
}

/** For tests or forced console-only mode */
export function useConsoleAdapterOnly(): void {
  adapter = createConsoleAdapter();
  initialized = true;
}
