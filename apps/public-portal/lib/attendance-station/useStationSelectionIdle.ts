"use client";

import { useEffect } from "react";
import { STATION_SELECTION_IDLE_MS } from "@/lib/attendance-station/kioskLock";

/** Després d'inactivitat, neteja la selecció d'empleat (sense demanar PIN). */
export function useStationSelectionIdle(
  enabled: boolean,
  onIdle: () => void,
  idleMs = STATION_SELECTION_IDLE_MS,
) {
  useEffect(() => {
    if (!enabled) return;

    let timer = window.setTimeout(onIdle, idleMs);
    const reset = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(onIdle, idleMs);
    };

    reset();
    const events: (keyof WindowEventMap)[] = ["pointerdown", "keydown", "touchstart"];
    for (const event of events) {
      window.addEventListener(event, reset);
    }

    return () => {
      window.clearTimeout(timer);
      for (const event of events) {
        window.removeEventListener(event, reset);
      }
    };
  }, [enabled, idleMs, onIdle]);
}
