"use client";

import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { formatLockoutRemaining } from "../utils/lockoutFormat";

interface IdentityDocumentGateProps {
  onSubmit: (documentId: string) => Promise<void>;
  errorCode?: string | null;
  retryAfterSeconds?: number | null;
}

export function IdentityDocumentGate({
  onSubmit,
  errorCode,
  retryAfterSeconds,
}: IdentityDocumentGateProps) {
  const { t } = useTranslation("portal");
  const [documentId, setDocumentId] = useState("");
  const [loading, setLoading] = useState(false);
  const [lockoutRemaining, setLockoutRemaining] = useState(retryAfterSeconds ?? 0);

  useEffect(() => {
    if (errorCode === "identity_mismatch" || errorCode === "identity_verify_failed") {
      setDocumentId("");
    }
  }, [errorCode]);

  useEffect(() => {
    if (errorCode !== "identity_locked" || !retryAfterSeconds) {
      setLockoutRemaining(0);
      return;
    }
    setLockoutRemaining(retryAfterSeconds);
    const id = window.setInterval(() => {
      setLockoutRemaining((prev) => (prev <= 1 ? 0 : prev - 1));
    }, 1000);
    return () => window.clearInterval(id);
  }, [errorCode, retryAfterSeconds]);

  const locked = lockoutRemaining > 0;

  const errorMessage =
    errorCode === "identity_locked" && locked
      ? t(
          "employee_portal.identity_locked",
          "Massa intents. Torna-ho a provar d'aquí {{time}}.",
          { time: formatLockoutRemaining(lockoutRemaining) },
        )
      : errorCode === "identity_mismatch" || errorCode === "identity_verify_failed"
        ? t(
            "employee_portal.identity_verify_failed",
            "No hem pogut verificar el document. Comprova les dades i torna-ho a provar.",
          )
        : errorCode === "identity_not_configured"
          ? t(
              "employee_portal.identity_not_configured_message",
              "No podem verificar la teva identitat perquè falta el document a l'empresa. Contacta recursos humans.",
            )
          : null;

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    const trimmed = documentId.trim();
    if (!trimmed || loading || locked) return;

    setLoading(true);
    try {
      await onSubmit(trimmed);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="mx-auto flex max-w-sm flex-col gap-6 px-4 py-10">
      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.identity_title", "Identifica't")}
        </h1>
        <p className="text-muted-foreground mt-2 text-sm">
          {t(
            "employee_portal.identity_subtitle",
            "Introdueix el teu DNI o NIE per continuar.",
          )}
        </p>
      </div>

      <form className="flex flex-col gap-4" onSubmit={(event) => void handleSubmit(event)}>
        <label className="flex flex-col gap-2 text-left text-sm">
          <span className="font-medium">
            {t("employee_portal.identity_document_label", "DNI / NIE")}
          </span>
          <input
            type="text"
            autoComplete="off"
            autoCapitalize="characters"
            spellCheck={false}
            inputMode="text"
            className="bg-background h-12 rounded-lg border px-3 font-mono text-base tracking-wide uppercase"
            placeholder={t(
              "employee_portal.identity_document_placeholder",
              "12345678Z",
            )}
            value={documentId}
            onChange={(event) => setDocumentId(event.target.value)}
            disabled={loading || locked}
            aria-invalid={Boolean(errorMessage)}
          />
        </label>

        {errorMessage && (
          <p className="text-destructive text-center text-sm" role="alert">
            {errorMessage}
          </p>
        )}

        <button
          type="submit"
          className="bg-primary text-primary-foreground hover:bg-primary/90 h-12 rounded-xl text-sm font-semibold disabled:opacity-50"
          disabled={loading || locked || documentId.trim().length < 4}
        >
          {loading
            ? t("employee_portal.identity_submitting", "Verificant…")
            : t("employee_portal.identity_submit", "Continuar")}
        </button>
      </form>
    </div>
  );
}
