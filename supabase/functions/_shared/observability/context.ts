export type ErrorContext = {
  tenantId?: string | null;
  userId?: string | null;
  siteId?: string | null;
  feature: string;
  correlationId?: string;
  tags?: Record<string, string>;
  extra?: Record<string, unknown>;
};

export type MessageLevel = "info" | "warning" | "error";

export interface SystemErrorTracker {
  captureException(error: unknown, ctx: ErrorContext): void;
  captureMessage(message: string, level: MessageLevel, ctx: ErrorContext): void;
}
