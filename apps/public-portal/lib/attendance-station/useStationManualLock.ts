"use client";

import { useCallback, useState } from "react";
import { verifyStationLocalPin } from "@/lib/attendance-station/client";
import { parseStationPinError, type StationPinErrorCode } from "@/lib/attendance-station/kioskLock";

/** Bloqueig manual amb PIN (ST-2b). El flux de fitxatge roman obert per defecte. */
export function useStationManualLock() {
  const [isManuallyLocked, setIsManuallyLocked] = useState(false);
  const [pinError, setPinError] = useState<StationPinErrorCode>(null);
  const [retryAfterSeconds, setRetryAfterSeconds] = useState<number | null>(null);

  const lock = useCallback(() => {
    setIsManuallyLocked(true);
    setPinError(null);
    setRetryAfterSeconds(null);
  }, []);

  const unlock = useCallback(async (pin: string) => {
    try {
      await verifyStationLocalPin(pin);
      setIsManuallyLocked(false);
      setPinError(null);
      setRetryAfterSeconds(null);
    } catch (err) {
      const code =
        err instanceof Error && err.message.startsWith("station_pin")
          ? err.message
          : "station_pin_invalid";
      const parsed = parseStationPinError(code);
      if (err instanceof Error && "retryAfterSeconds" in err && typeof err.retryAfterSeconds === "number") {
        parsed.retryAfterSeconds = err.retryAfterSeconds;
      }
      setPinError(parsed.code);
      setRetryAfterSeconds(parsed.retryAfterSeconds);
      throw err;
    }
  }, []);

  return {
    isManuallyLocked,
    lock,
    unlock,
    pinError,
    retryAfterSeconds,
  };
}
