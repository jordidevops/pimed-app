"use client";

import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { useTranslation } from "react-i18next";

function PortalExpiredInner() {
  const searchParams = useSearchParams();
  const { t } = useTranslation("portal");
  const reason = searchParams.get("reason");

  const title =
    reason === "shared_rescan"
      ? t("employee_portal.expired_shared_title", "Torna a escanejar el teu QR")
      : reason === "idle"
        ? t("employee_portal.expired_idle_title", "Sessió tancada per inactivitat")
        : reason === "logged_out"
          ? t("employee_portal.expired_logged_out_title", "Sessió tancada")
          : t("employee_portal.expired_title", "Enllaç caducat o revocat");

  const message =
    reason === "shared_rescan"
      ? t(
          "employee_portal.expired_shared_message",
          "Escaneja de nou el QR del taulell compartit per accedir al portal.",
        )
      : reason === "idle"
        ? t(
            "employee_portal.expired_idle_message",
            "Has estat inactiu massa temps. Escaneja el teu QR per tornar a entrar.",
          )
        : reason === "logged_out"
          ? t(
              "employee_portal.expired_logged_out_message",
              "Has tancat la sessió correctament. El següent empleat pot escanejar el seu QR.",
            )
          : t(
              "employee_portal.expired_message",
              "Demana un enllaç nou al teu responsable per accedir al portal.",
            );

  return (
    <div className="mx-auto max-w-md space-y-3 px-4 text-center">
      <h1 className="text-xl font-semibold">{title}</h1>
      <p className="text-muted-foreground text-sm">{message}</p>
    </div>
  );
}

export default function PortalExpiredPage() {
  return (
    <Suspense fallback={<div className="mx-auto max-w-md px-4 text-center text-sm">…</div>}>
      <PortalExpiredInner />
    </Suspense>
  );
}
