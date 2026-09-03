export function classifyNotificationError(err: unknown): {
  errorCode: string;
  errorMessage: string;
  isBusinessError: boolean;
} {
  const message = err instanceof Error
    ? err.message
    : err && typeof err === "object" && "message" in err
    ? String((err as { message: unknown }).message)
    : String(err);

  if (message.includes("20003") || message.includes("Authenticate")) {
    return { errorCode: "TWILIO_INVALID_CREDENTIALS", errorMessage: message, isBusinessError: true };
  }
  if (message.includes("21610") || message.includes("insufficient")) {
    return { errorCode: "TWILIO_INSUFFICIENT_BALANCE", errorMessage: message, isBusinessError: true };
  }
  if (message.includes("rate_limit") || message.includes("daily_quota")) {
    return { errorCode: "RESEND_RATE_LIMIT", errorMessage: message, isBusinessError: true };
  }
  if (message.includes("ONESIGNAL_NOT_CONFIGURED") || message.includes("push_only_for")) {
    return { errorCode: "PUSH_NOT_AVAILABLE", errorMessage: message, isBusinessError: true };
  }
  if (message.includes("TWILIO_NOT_CONFIGURED")) {
    return { errorCode: "TWILIO_NOT_CONFIGURED", errorMessage: message, isBusinessError: true };
  }

  return { errorCode: "NOTIFICATION_SEND_FAILED", errorMessage: message, isBusinessError: false };
}
