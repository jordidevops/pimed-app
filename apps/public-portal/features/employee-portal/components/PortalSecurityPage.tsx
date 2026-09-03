"use client";

import { useState } from "react";
import { useTranslation } from "react-i18next";
import { changePortalPin, PortalApiError } from "../api/portalApi";
import { PinGate } from "./PinGate";

export function PortalSecurityPage() {
  const { t } = useTranslation("portal");
  const [currentPin, setCurrentPin] = useState<string | null>(null);
  const [newPin, setNewPin] = useState("");
  const [confirmPin, setConfirmPin] = useState("");
  const [errorCode, setErrorCode] = useState<string | null>(null);
  const [retryAfterSeconds, setRetryAfterSeconds] = useState<number | null>(null);
  const [success, setSuccess] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  async function handleCurrentPin(pin: string) {
    setErrorCode(null);
    setRetryAfterSeconds(null);
    setCurrentPin(pin);
    setNewPin("");
    setConfirmPin("");
  }

  async function handleSubmitNewPin() {
    if (!currentPin || newPin.length < 4 || submitting) return;
    if (newPin !== confirmPin) {
      setErrorCode("pin_mismatch");
      return;
    }

    setSubmitting(true);
    setErrorCode(null);
    setRetryAfterSeconds(null);
    setSuccess(false);

    try {
      await changePortalPin(currentPin, newPin, confirmPin);
      setSuccess(true);
      setCurrentPin(null);
      setNewPin("");
      setConfirmPin("");
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "change_failed";
      setErrorCode(code);
      if (err instanceof PortalApiError) {
        setRetryAfterSeconds(err.retryAfterSeconds ?? null);
      }
      if (code === "pin_invalid" || code === "pin_locked") {
        setCurrentPin(null);
      }
    } finally {
      setSubmitting(false);
    }
  }

  if (!currentPin) {
    return (
      <PinGate
        onSubmit={handleCurrentPin}
        errorCode={errorCode}
        retryAfterSeconds={retryAfterSeconds}
      />
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">
          {t("employee_portal.security_title", "Seguretat")}
        </h1>
        <p className="text-muted-foreground mt-1 text-sm">
          {t("employee_portal.security_subtitle", "Canvia el teu PIN del portal.")}
        </p>
      </div>

      {success ? (
        <p className="rounded-lg border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-900 dark:border-green-900 dark:bg-green-950/30 dark:text-green-100">
          {t("employee_portal.security_pin_changed", "PIN actualitzat correctament.")}
        </p>
      ) : null}

      <div className="space-y-4">
        <div className="space-y-1">
          <label className="text-sm font-medium" htmlFor="portal-new-pin">
            {t("employee_portal.security_new_pin", "PIN nou")}
          </label>
          <input
            id="portal-new-pin"
            type="password"
            inputMode="numeric"
            autoComplete="off"
            maxLength={6}
            value={newPin}
            onChange={(e) => setNewPin(e.target.value.replace(/\D/g, ""))}
            className="border-input bg-background w-full rounded-lg border px-3 py-2 text-base"
          />
        </div>
        <div className="space-y-1">
          <label className="text-sm font-medium" htmlFor="portal-confirm-pin">
            {t("employee_portal.security_confirm_pin", "Confirma el PIN nou")}
          </label>
          <input
            id="portal-confirm-pin"
            type="password"
            inputMode="numeric"
            autoComplete="off"
            maxLength={6}
            value={confirmPin}
            onChange={(e) => setConfirmPin(e.target.value.replace(/\D/g, ""))}
            className="border-input bg-background w-full rounded-lg border px-3 py-2 text-base"
          />
        </div>

        {errorCode === "pin_mismatch" ? (
          <p className="text-destructive text-sm">
            {t("employee_portal.pin_setup_mismatch", "Els PIN no coincideixen. Torna-ho a provar.")}
          </p>
        ) : null}
        {errorCode === "pin_locked" && retryAfterSeconds ? (
          <p className="text-destructive text-sm">
            {t("employee_portal.pin_locked", "Massa intents. Torna-ho a provar d'aquí {{time}}.", {
              time: `${Math.ceil(retryAfterSeconds / 60)} min`,
            })}
          </p>
        ) : null}
        {errorCode && errorCode !== "pin_mismatch" && errorCode !== "pin_locked" ? (
          <p className="text-destructive text-sm">
            {t("employee_portal.security_change_error", "No s'ha pogut canviar el PIN.")}
          </p>
        ) : null}

        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            className="bg-primary text-primary-foreground hover:bg-primary/90 rounded-lg px-4 py-2 text-sm font-medium disabled:opacity-50"
            disabled={submitting || newPin.length < 4 || confirmPin.length < 4}
            onClick={() => void handleSubmitNewPin()}
          >
            {submitting
              ? t("employee_portal.pin_submitting", "Validant…")
              : t("employee_portal.security_save_pin", "Desar PIN")}
          </button>
          <button
            type="button"
            className="hover:bg-muted rounded-lg border px-4 py-2 text-sm"
            onClick={() => {
              setCurrentPin(null);
              setErrorCode(null);
            }}
          >
            {t("employee_portal.security_cancel", "Cancel·lar")}
          </button>
        </div>
      </div>
    </div>
  );
}
