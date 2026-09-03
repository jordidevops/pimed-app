"use client";

import { useCallback, useEffect, useState } from "react";
import { formatLockoutRemaining } from "@/lib/attendance-station/kioskLock";

interface StationPinPadProps {
  title?: string;
  subtitle?: string;
  onSubmit: (pin: string) => Promise<void>;
  errorCode?: "invalid" | "locked" | null;
  retryAfterSeconds?: number | null;
  submitLabel?: string;
}

export function StationPinPad({
  title = "PIN de l'estació",
  subtitle = "4 a 6 dígits — desbloqueja el kiosk",
  onSubmit,
  errorCode = null,
  retryAfterSeconds = null,
  submitLabel = "Desbloquejar",
}: StationPinPadProps) {
  const [pin, setPin] = useState("");
  const [loading, setLoading] = useState(false);
  const [lockoutRemaining, setLockoutRemaining] = useState(retryAfterSeconds ?? 0);

  useEffect(() => {
    if (errorCode === "invalid") {
      setPin("");
    }
  }, [errorCode]);

  useEffect(() => {
    if (errorCode !== "locked" || !retryAfterSeconds) {
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
    setPin((prev) => (prev.length >= 6 ? prev : prev + digit));
  }, []);

  const backspace = useCallback(() => {
    setPin((prev) => prev.slice(0, -1));
  }, []);

  async function handleSubmit() {
    if (pin.length < 4 || loading || lockoutRemaining > 0) return;
    setLoading(true);
    try {
      await onSubmit(pin);
      setPin("");
    } catch {
      setPin("");
    } finally {
      setLoading(false);
    }
  }

  const errorMessage =
    errorCode === "locked" && lockoutRemaining > 0
      ? `Massa intents. Torna-ho a provar d'aquí ${formatLockoutRemaining(lockoutRemaining)}.`
      : errorCode === "invalid"
        ? "PIN incorrecte"
        : null;

  return (
    <div className="mx-auto flex max-w-sm flex-col items-center gap-6 px-4 py-10">
      <div className="text-center">
        <h1 className="text-2xl font-semibold">{title}</h1>
        <p className="mt-2 text-sm text-muted-foreground">{subtitle}</p>
      </div>

      <div
        className="flex h-14 min-w-[10rem] items-center justify-center gap-2 rounded-xl border bg-muted/40 px-4 font-mono text-2xl tracking-[0.35em]"
        aria-live="polite"
      >
        {pin.length === 0 ? (
          <span className="text-base tracking-normal text-muted-foreground">••••</span>
        ) : (
          "•".repeat(pin.length)
        )}
      </div>

      {errorMessage ? (
        <p className="text-center text-sm text-destructive" role="alert">
          {errorMessage}
        </p>
      ) : null}

      <div className="grid w-full max-w-[300px] grid-cols-3 gap-3 touch-manipulation">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((digit) => (
          <button
            key={digit}
            type="button"
            className="h-16 select-none rounded-2xl border bg-card text-2xl font-medium hover:bg-muted active:bg-muted disabled:opacity-50"
            onClick={() => appendDigit(digit)}
            disabled={loading || lockoutRemaining > 0}
          >
            {digit}
          </button>
        ))}
        <button
          type="button"
          className="h-16 select-none rounded-2xl border bg-card text-sm hover:bg-muted active:bg-muted disabled:opacity-50"
          onClick={backspace}
          disabled={loading || pin.length === 0}
          aria-label="Esborrar"
        >
          ⌫
        </button>
        <button
          type="button"
          className="h-16 select-none rounded-2xl border bg-card text-2xl font-medium hover:bg-muted active:bg-muted disabled:opacity-50"
          onClick={() => appendDigit("0")}
          disabled={loading || lockoutRemaining > 0}
        >
          0
        </button>
        <button
          type="button"
          className="h-16 select-none rounded-2xl bg-primary text-sm font-semibold text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          onClick={() => void handleSubmit()}
          disabled={loading || pin.length < 4 || lockoutRemaining > 0}
        >
          {loading ? "Validant…" : submitLabel}
        </button>
      </div>
    </div>
  );
}
