"use client";

import { Suspense, useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { useTranslation } from "react-i18next";
import { PinSetupGate } from "@/features/employee-portal/components/PinSetupGate";
import {
  consumePortalPinReset,
  PortalApiError,
  validatePortalPinReset,
} from "@/features/employee-portal/api/portalApi";

type ResetPhase = "loading" | "form" | "success" | "error";

function EmployeePortalPinResetInner() {
  const params = useParams<{ secret: string }>();
  const { t } = useTranslation("portal");
  const [phase, setPhase] = useState<ResetPhase>("loading");
  const [errorCode, setErrorCode] = useState<string | null>(null);
  const [employeeName, setEmployeeName] = useState<string | null>(null);
  const secret = params.secret;

  useEffect(() => {
    if (!secret) return;

    let cancelled = false;
    setPhase("loading");
    setErrorCode(null);

    void validatePortalPinReset(secret)
      .then((result) => {
        if (cancelled) return;
        setEmployeeName(result.employee_name);
        setPhase("form");
      })
      .catch((err) => {
        if (cancelled) return;
        setPhase("error");
        setErrorCode(err instanceof PortalApiError ? err.code : "pin_reset_invalid");
      });

    return () => {
      cancelled = true;
    };
  }, [secret]);

  const handleSubmit = useCallback(
    async (pin: string, confirmPin: string) => {
      if (!secret) return;
      setErrorCode(null);

      try {
        await consumePortalPinReset(secret, pin, confirmPin);
        setPhase("success");
      } catch (err) {
        const code = err instanceof PortalApiError ? err.code : "pin_reset_failed";
        setErrorCode(code);
        throw err;
      }
    },
    [secret],
  );

  if (phase === "success") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center space-y-3">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.pin_reset_success_title", "PIN restablert")}
        </h1>
        <p className="text-muted-foreground text-sm">
          {t(
            "employee_portal.pin_reset_success_body",
            "Ja pots tornar a entrar amb el teu enllaç d'accés habitual i el PIN nou.",
          )}
        </p>
      </div>
    );
  }

  if (phase === "error") {
    const message =
      errorCode === "pin_reset_expired"
        ? t("employee_portal.pin_reset_expired", "Aquest enllaç ha caducat. Demana'n un de nou al teu responsable.")
        : errorCode === "pin_reset_used"
          ? t("employee_portal.pin_reset_used", "Aquest enllaç ja s'ha utilitzat.")
          : errorCode === "pin_reset_revoked"
            ? t("employee_portal.pin_reset_revoked", "Aquest enllaç ja no és vàlid.")
            : t("employee_portal.pin_reset_invalid", "Enllaç de restabliment no vàlid.");

    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center space-y-3">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.pin_reset_error_title", "No s'ha pogut restablir el PIN")}
        </h1>
        <p className="text-muted-foreground text-sm">{message}</p>
      </div>
    );
  }

  if (phase === "form") {
    return (
      <div className="space-y-2">
        {employeeName ? (
          <p className="text-center text-sm text-muted-foreground pt-4">
            {t("employee_portal.pin_reset_for", "Restabliment de PIN per a {{name}}", {
              name: employeeName,
            })}
          </p>
        ) : null}
        <PinSetupGate
          mode="reset"
          onSubmit={handleSubmit}
          errorCode={errorCode}
        />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-md px-4 py-16 text-center text-sm">
      {t("employee_portal.pin_reset_loading", "Comprovant enllaç…")}
    </div>
  );
}

export default function EmployeePortalPinResetPage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto max-w-md px-4 py-16 text-center text-sm">…</div>
      }
    >
      <EmployeePortalPinResetInner />
    </Suspense>
  );
}
