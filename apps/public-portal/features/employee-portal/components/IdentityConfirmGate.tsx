"use client";

import { useState } from "react";
import { useTranslation } from "react-i18next";

interface IdentityConfirmGateProps {
  fullName: string;
  onConfirm: () => Promise<void>;
  onReject: () => Promise<void>;
  errorCode?: string | null;
}

export function IdentityConfirmGate({
  fullName,
  onConfirm,
  onReject,
  errorCode,
}: IdentityConfirmGateProps) {
  const { t } = useTranslation("portal");
  const [loadingAction, setLoadingAction] = useState<"confirm" | "reject" | null>(null);

  const errorMessage =
    errorCode === "identity_challenge_required"
      ? t(
          "employee_portal.identity_challenge_required",
          "La verificació ha caducat. Torna a introduir el teu document.",
        )
      : errorCode
        ? t("employee_portal.bootstrap_error", "No s'ha pogut obrir el portal")
        : null;

  async function handleConfirm() {
    if (loadingAction) return;
    setLoadingAction("confirm");
    try {
      await onConfirm();
    } finally {
      setLoadingAction(null);
    }
  }

  async function handleReject() {
    if (loadingAction) return;
    setLoadingAction("reject");
    try {
      await onReject();
    } finally {
      setLoadingAction(null);
    }
  }

  return (
    <div className="mx-auto flex max-w-sm flex-col gap-6 px-4 py-10">
      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.identity_confirm_title", "Confirmació d'identitat")}
        </h1>
        <p className="text-muted-foreground mt-4 text-base">
          {t("employee_portal.identity_confirm_greeting", "Hola,")}
        </p>
        <p className="mt-1 text-2xl font-semibold tracking-tight">{fullName}</p>
        <p className="text-muted-foreground mt-3 text-sm">
          {t(
            "employee_portal.identity_confirm_prompt",
            "Confirma que ets tu per continuar.",
          )}
        </p>
      </div>

      <div
        className="bg-muted/50 rounded-lg border px-4 py-3 text-sm"
        role="note"
      >
        {t(
          "employee_portal.identity_confirm_warning",
          "Si no ets aquesta persona, no continuïs i tanca aquesta pàgina.",
        )}
      </div>

      {errorMessage && (
        <p className="text-destructive text-center text-sm" role="alert">
          {errorMessage}
        </p>
      )}

      <div className="flex flex-col gap-3">
        <button
          type="button"
          className="bg-primary text-primary-foreground hover:bg-primary/90 h-12 rounded-xl text-sm font-semibold disabled:opacity-50"
          onClick={() => void handleConfirm()}
          disabled={loadingAction !== null}
        >
          {loadingAction === "confirm"
            ? t("employee_portal.identity_confirm_submitting", "Confirmant…")
            : t("employee_portal.identity_confirm_yes", "Sí, sóc jo")}
        </button>
        <button
          type="button"
          className="hover:bg-muted h-12 rounded-xl border text-sm font-medium disabled:opacity-50"
          onClick={() => void handleReject()}
          disabled={loadingAction !== null}
        >
          {loadingAction === "reject"
            ? t("employee_portal.identity_reject_submitting", "Sortint…")
            : t("employee_portal.identity_confirm_reject", "No sóc aquesta persona")}
        </button>
      </div>
    </div>
  );
}
