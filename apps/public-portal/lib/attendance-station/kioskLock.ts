/** Temps sense interacció abans de deseleccionar l'empleat (no demana PIN). */
export const STATION_SELECTION_IDLE_MS = 90_000;

export type StationPinErrorCode = "invalid" | "locked" | null;

export function parseStationPinError(message: string): {
  code: StationPinErrorCode;
  retryAfterSeconds: number | null;
} {
  if (message.includes("station_pin_locked")) {
    const match = message.match(/retry_after_seconds[":\s]+(\d+)/);
    return {
      code: "locked",
      retryAfterSeconds: match ? Number(match[1]) : 900,
    };
  }
  if (message.includes("station_pin_invalid") || message.includes("invalid_local_pin")) {
    return { code: "invalid", retryAfterSeconds: null };
  }
  return { code: "invalid", retryAfterSeconds: null };
}

export function formatLockoutRemaining(seconds: number): string {
  if (seconds < 60) {
    return seconds <= 1 ? "1 s" : `${seconds} s`;
  }
  const mins = Math.ceil(seconds / 60);
  return mins <= 1 ? "1 min" : `${mins} min`;
}
