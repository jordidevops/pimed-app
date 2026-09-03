"use client";

import { useCallback, useEffect, useState } from "react";
import type { StationEmployeeRow } from "@/lib/attendance-station/punchUi";
import type { StationIdentityConfirm } from "@/lib/attendance-station/client";

export type StationPhase =
  | "waiting"
  | "confirm_identity"
  | "confirm_pin"
  | "employee_session"
  | "success_flash"
  | "history_pin"
  | "history";

export type SessionIdentitySource = "list" | "qr" | "document";

export type StationSessionEmployee = StationEmployeeRow & {
  identitySource: SessionIdentitySource;
  identityToken?: string | null;
  scheduled_location_name?: string | null;
  scheduled_location_path?: string | null;
  wrong_scheduled_location?: boolean;
  warn_wrong_scheduled_location?: boolean;
  outside_assignment?: boolean;
  warn_unassigned_punch?: boolean;
};

export type StationSessionTimers = {
  idleSeconds: number;
  countdownSeconds: number;
  identityConfirm: StationIdentityConfirm;
  qrIdentityConfirm: StationIdentityConfirm;
};

function confirmModeForSource(
  source: SessionIdentitySource,
  timers: StationSessionTimers,
): StationIdentityConfirm {
  if (source === "qr") return timers.qrIdentityConfirm;
  // Document-first: default to tap_name when station left at MVP "none".
  if (source === "document" && timers.identityConfirm === "none") return "tap_name";
  return timers.identityConfirm;
}

export function useStationSession(timers: StationSessionTimers) {
  const [phase, setPhase] = useState<StationPhase>("waiting");
  const [employee, setEmployee] = useState<StationSessionEmployee | null>(null);
  const [pending, setPending] = useState<StationSessionEmployee | null>(null);
  const [flashMessage, setFlashMessage] = useState<string | null>(null);
  const [countdownRemaining, setCountdownRemaining] = useState<number | null>(null);
  const [historyPin, setHistoryPin] = useState<string | null>(null);

  const idleMs = Math.max(15, timers.idleSeconds) * 1000;
  const countdownSec = Math.max(5, timers.countdownSeconds);

  const endSession = useCallback(() => {
    setPhase("waiting");
    setEmployee(null);
    setPending(null);
    setFlashMessage(null);
    setCountdownRemaining(null);
    setHistoryPin(null);
  }, []);

  const beginSession = useCallback((sessionEmployee: StationSessionEmployee) => {
    setPending(null);
    setEmployee(sessionEmployee);
    setFlashMessage(null);
    setCountdownRemaining(null);
    setHistoryPin(null);
    setPhase("employee_session");
  }, []);

  const selectEmployee = useCallback(
    (row: StationEmployeeRow, source: SessionIdentitySource, identityToken?: string | null) => {
      const next: StationSessionEmployee = {
        ...row,
        identitySource: source,
        identityToken: identityToken ?? null,
      };
      const confirmMode = confirmModeForSource(source, timers);
      if (confirmMode === "tap_name") {
        setPending(next);
        setEmployee(null);
        setFlashMessage(null);
        setCountdownRemaining(null);
        setPhase("confirm_identity");
        return;
      }
      if (confirmMode === "portal_pin") {
        setPending(next);
        setEmployee(null);
        setFlashMessage(null);
        setCountdownRemaining(null);
        setPhase("confirm_pin");
        return;
      }
      beginSession(next);
    },
    [beginSession, timers],
  );

  const confirmIdentity = useCallback(() => {
    if (!pending) return;
    beginSession(pending);
  }, [beginSession, pending]);

  const confirmPinSuccess = useCallback(() => {
    if (!pending) return;
    beginSession(pending);
  }, [beginSession, pending]);

  /** Employee has no portal PIN configured → fall back to name confirm. */
  const fallbackPinToTapName = useCallback(() => {
    if (!pending) return;
    setPhase("confirm_identity");
  }, [pending]);

  const cancelConfirm = useCallback(() => {
    setPending(null);
    setPhase("waiting");
  }, []);

  const notePunchSuccess = useCallback(
    (message: string, updatedEmployee?: StationSessionEmployee | null) => {
      if (updatedEmployee) {
        setEmployee(updatedEmployee);
      }
      setFlashMessage(message);
      setCountdownRemaining(countdownSec);
      setPhase("success_flash");
    },
    [countdownSec],
  );

  const touchActivity = useCallback(() => {
    setCountdownRemaining(null);
    setFlashMessage(null);
    if (phase === "history" || phase === "history_pin") return;
    setPhase("employee_session");
  }, [phase]);

  const openHistory = useCallback(() => {
    if (!employee) return;
    setFlashMessage(null);
    setCountdownRemaining(null);
    setHistoryPin(null);
    setPhase("history_pin");
  }, [employee]);

  const confirmHistoryPin = useCallback((pin: string) => {
    setHistoryPin(pin);
    setPhase("history");
  }, []);

  const closeHistory = useCallback(() => {
    setHistoryPin(null);
    setPhase("employee_session");
  }, []);

  const syncEmployeeFromList = useCallback((rows: StationEmployeeRow[]) => {
    setEmployee((current) => {
      if (!current) return current;
      const fresh = rows.find((row) => row.employee_id === current.employee_id);
      if (!fresh) return current;
      return {
        ...current,
        ...fresh,
        identitySource: current.identitySource,
        identityToken: current.identityToken,
        scheduled_location_name: current.scheduled_location_name,
        scheduled_location_path: current.scheduled_location_path,
        wrong_scheduled_location: current.wrong_scheduled_location,
        warn_wrong_scheduled_location: current.warn_wrong_scheduled_location,
        outside_assignment: current.outside_assignment,
        warn_unassigned_punch: current.warn_unassigned_punch,
      };
    });
  }, []);

  const patchSessionEmployee = useCallback((patch: Partial<StationSessionEmployee>) => {
    setEmployee((current) => (current ? { ...current, ...patch } : current));
  }, []);

  useEffect(() => {
    if (phase === "waiting") return;

    let timer = window.setTimeout(endSession, idleMs);
    const onActivity = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(endSession, idleMs);
      if (phase === "success_flash") {
        touchActivity();
      }
    };

    const events: (keyof WindowEventMap)[] = ["pointerdown", "keydown", "touchstart"];
    for (const event of events) {
      window.addEventListener(event, onActivity);
    }

    return () => {
      window.clearTimeout(timer);
      for (const event of events) {
        window.removeEventListener(event, onActivity);
      }
    };
  }, [phase, idleMs, endSession, touchActivity]);

  useEffect(() => {
    if (phase !== "success_flash" || countdownRemaining === null) return;

    if (countdownRemaining <= 0) {
      endSession();
      return;
    }

    const timer = window.setTimeout(() => {
      setCountdownRemaining((prev) => (prev === null ? null : prev - 1));
    }, 1000);

    return () => window.clearTimeout(timer);
  }, [phase, countdownRemaining, endSession]);

  return {
    phase,
    employee,
    pending,
    flashMessage,
    countdownRemaining,
    historyPin,
    selectEmployee,
    confirmIdentity,
    confirmPinSuccess,
    fallbackPinToTapName,
    cancelConfirm,
    endSession,
    notePunchSuccess,
    touchActivity,
    openHistory,
    confirmHistoryPin,
    closeHistory,
    syncEmployeeFromList,
    patchSessionEmployee,
  };
}
