"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { formatLockoutRemaining } from "../utils/lockoutFormat";

interface PinGateProps {
  onSubmit: (pin: string) => Promise<void>;
  errorCode?: string | null;
  retryAfterSeconds?: number | null;
}

export function PinGate({ onSubmit, errorCode, retryAfterSeconds }: PinGateProps) {
  const { t } = useTranslation("portal");
  const [pin, setPin] = useState("");
  const [loading, setLoading] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [lockoutRemaining, setLockoutRemaining] = useState(retryAfterSeconds ?? 0);

  useEffect(() => {
    if (errorCode === "pin_invalid") {
      setPin("");
    }
  }, [errorCode]);

  useEffect(() => {
    if (errorCode !== "pin_locked" || !retryAfterSeconds) {
      setLockoutRemaining(0);
      return;
    }
    setLockoutRemaining(retryAfterSeconds);
    const id = window.setInterval(() => {
      setLockoutRemaining((prev) => (prev <= 1 ? 0 : prev - 1));
    }, 1000);
    return () => window.clearInterval(id);
  }, [errorCode, retryAfterSeconds]);

  const appendDigit = useCallback((digit: string) => {
    setLocalError(null);
    setPin((prev) => (prev.length >= 6 ? prev : prev + digit));
  }, []);

  const backspace = useCallback(() => {
    setLocalError(null);
    setPin((prev) => prev.slice(0, -1));
  }, []);

  async function handleSubmit() {
    if (pin.length < 4 || loading) return;
    setLoading(true);
    setLocalError(null);
    try {
      await onSubmit(pin);
      setPin("");
    } catch {
      setPin("");
      setLocalError(t("employee_portal.pin_invalid", "PIN incorrecte"));
    } finally {
      setLoading(false);
    }
  }

  const errorMessage =
    localError ??
    (errorCode === "pin_locked" && lockoutRemaining > 0
      ? t("employee_portal.pin_locked", "Massa intents. Torna-ho a provar d'aquí {{time}}.", {
          time: formatLockoutRemaining(lockoutRemaining),
        })
      : errorCode === "pin_invalid"
      ? t("employee_portal.pin_invalid", "PIN incorrecte")
      : errorCode === "pin_required" || errorCode === "offline_pin"
        ? t("employee_portal.offline_pin", "Cal connexió per validar el PIN la primera vegada")
        : errorCode
          ? t("employee_portal.bootstrap_error", "No s'ha pogut obrir el portal")
          : null);

  return (
    <div className="mx-auto flex max-w-sm flex-col items-center gap-6 px-4 py-10">
      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.pin_title", "Introdueix el teu PIN")}
        </h1>
        <p className="text-muted-foreground mt-2 text-sm">
          {t(
            "employee_portal.pin_subtitle",
            "4 a 6 dígits — fes servir el teclat numèric de sota",
          )}
        </p>
      </div>

      <div
        className="flex h-12 min-w-[8rem] items-center justify-center gap-2 rounded-lg border bg-muted/40 px-4 font-mono text-2xl tracking-[0.35em]"
        aria-live="polite"
        aria-label={t("employee_portal.pin_title", "Introdueix el teu PIN")}
      >
        {pin.length === 0 ? (
          <span className="text-muted-foreground text-base tracking-normal">••••</span>
        ) : (
          "•".repeat(pin.length)
        )}
      </div>

      {errorMessage && (
        <p className="text-destructive text-center text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      <div className="grid w-full max-w-[280px] grid-cols-3 gap-2 touch-manipulation">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((digit) => (
          <button
            key={digit}
            type="button"
            className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-xl font-medium select-none"
            onClick={() => appendDigit(digit)}
            disabled={loading || lockoutRemaining > 0}
          >
            {digit}
          </button>
        ))}
        <button
          type="button"
          className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-sm select-none"
          onClick={backspace}
          disabled={loading || pin.length === 0}
          aria-label={t("employee_portal.pin_backspace", "Esborrar")}
        >
          ⌫
        </button>
        <button
          type="button"
          className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-xl font-medium select-none"
          onClick={() => appendDigit("0")}
          disabled={loading}
        >
          0
        </button>
        <button
          type="button"
          className="bg-primary text-primary-foreground hover:bg-primary/90 active:bg-primary/80 h-14 rounded-xl text-sm font-semibold disabled:opacity-50 select-none"
          onClick={() => void handleSubmit()}
          disabled={loading || pin.length < 4 || lockoutRemaining > 0}
        >
          {loading
            ? t("employee_portal.pin_submitting", "Validant…")
            : t("employee_portal.pin_submit", "Entrar")}
        </button>
      </div>
    </div>
  );
}
