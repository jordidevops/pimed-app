"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { formatLockoutRemaining } from "../utils/lockoutFormat";

type SetupStep = "new" | "confirm";

interface PinSetupGateProps {
  onSubmit: (pin: string, confirmPin: string) => Promise<void>;
  errorCode?: string | null;
  retryAfterSeconds?: number | null;
  mode?: "setup" | "reset";
}

export function PinSetupGate({ onSubmit, errorCode, retryAfterSeconds, mode = "setup" }: PinSetupGateProps) {
  const { t } = useTranslation("portal");
  const [step, setStep] = useState<SetupStep>("new");
  const [newPin, setNewPin] = useState("");
  const [confirmPin, setConfirmPin] = useState("");
  const [activePin, setActivePin] = useState("");
  const [loading, setLoading] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [lockoutRemaining, setLockoutRemaining] = useState(retryAfterSeconds ?? 0);

  useEffect(() => {
    if (errorCode === "pin_mismatch" || errorCode === "pin_invalid") {
      setStep("new");
      setNewPin("");
      setConfirmPin("");
      setActivePin("");
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

  const appendDigit = useCallback(
    (digit: string) => {
      if (lockoutRemaining > 0) return;
      setLocalError(null);
      setActivePin((prev) => (prev.length >= 6 ? prev : prev + digit));
    },
    [lockoutRemaining],
  );

  const backspace = useCallback(() => {
    if (lockoutRemaining > 0) return;
    setLocalError(null);
    setActivePin((prev) => prev.slice(0, -1));
  }, [lockoutRemaining]);

  async function handleContinue() {
    if (activePin.length < 4 || loading || lockoutRemaining > 0) return;

    if (step === "new") {
      setNewPin(activePin);
      setActivePin("");
      setStep("confirm");
      return;
    }

    setConfirmPin(activePin);
    if (activePin !== newPin) {
      setLocalError(t("employee_portal.pin_setup_mismatch", "Els PIN no coincideixen. Torna-ho a provar."));
      setStep("new");
      setNewPin("");
      setConfirmPin("");
      setActivePin("");
      return;
    }

    setLoading(true);
    setLocalError(null);
    try {
      await onSubmit(newPin, activePin);
      setNewPin("");
      setConfirmPin("");
      setActivePin("");
      setStep("new");
    } catch {
      setActivePin("");
      setLocalError(
        mode === "reset"
          ? t("employee_portal.pin_reset_error", "No s'ha pogut restablir el PIN.")
          : t("employee_portal.pin_setup_error", "No s'ha pogut establir el PIN."),
      );
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
      : errorCode === "pin_already_set"
        ? t("employee_portal.pin_already_set", "El PIN ja estava definit. Torna a entrar.")
        : errorCode === "pin_mismatch"
          ? t("employee_portal.pin_setup_mismatch", "Els PIN no coincideixen. Torna-ho a provar.")
          : errorCode === "invalid_pin"
            ? t("employee_portal.pin_setup_invalid", "El PIN ha de tenir 4 a 6 dígits.")
            : null);

  return (
    <div className="mx-auto flex max-w-sm flex-col items-center gap-6 px-4 py-10">
      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {mode === "reset"
            ? t("employee_portal.pin_reset_title", "Tria un PIN nou")
            : t("employee_portal.pin_setup_title", "Defineix el teu PIN")}
        </h1>
        <p className="text-muted-foreground mt-2 text-sm">
          {step === "new"
            ? mode === "reset"
              ? t(
                  "employee_portal.pin_reset_subtitle_new",
                  "Introdueix un PIN nou de 4 a 6 dígits.",
                )
              : t(
                  "employee_portal.pin_setup_subtitle_new",
                  "Tria un PIN de 4 a 6 dígits. Només tu el coneixeràs.",
                )
            : mode === "reset"
              ? t(
                  "employee_portal.pin_reset_subtitle_confirm",
                  "Torna a introduir el mateix PIN per confirmar.",
                )
              : t(
                  "employee_portal.pin_setup_subtitle_confirm",
                  "Torna a introduir el mateix PIN per confirmar.",
                )}
        </p>
      </div>

      <div
        className="flex h-12 min-w-[8rem] items-center justify-center gap-2 rounded-lg border bg-muted/40 px-4 font-mono text-2xl tracking-[0.35em]"
        aria-live="polite"
      >
        {activePin.length === 0 ? (
          <span className="text-muted-foreground text-base tracking-normal">••••</span>
        ) : (
          "•".repeat(activePin.length)
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
            className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-xl font-medium select-none disabled:opacity-50"
            onClick={() => appendDigit(digit)}
            disabled={loading || lockoutRemaining > 0}
          >
            {digit}
          </button>
        ))}
        <button
          type="button"
          className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-sm select-none disabled:opacity-50"
          onClick={backspace}
          disabled={loading || activePin.length === 0 || lockoutRemaining > 0}
          aria-label={t("employee_portal.pin_backspace", "Esborrar")}
        >
          ⌫
        </button>
        <button
          type="button"
          className="bg-card hover:bg-muted active:bg-muted h-14 rounded-xl border text-xl font-medium select-none disabled:opacity-50"
          onClick={() => appendDigit("0")}
          disabled={loading || lockoutRemaining > 0}
        >
          0
        </button>
        <button
          type="button"
          className="bg-primary text-primary-foreground hover:bg-primary/90 active:bg-primary/80 h-14 rounded-xl text-sm font-semibold disabled:opacity-50 select-none"
          onClick={() => void handleContinue()}
          disabled={loading || activePin.length < 4 || lockoutRemaining > 0}
        >
          {loading
            ? t("employee_portal.pin_submitting", "Validant…")
            : step === "new"
              ? t("employee_portal.pin_setup_continue", "Continuar")
              : mode === "reset"
                ? t("employee_portal.pin_reset_submit", "Restablir PIN")
                : t("employee_portal.pin_setup_submit", "Establir PIN")}
        </button>
      </div>
    </div>
  );
}
