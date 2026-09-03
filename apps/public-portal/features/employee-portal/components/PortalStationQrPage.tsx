"use client";

import Link from "next/link";
import { useTranslation } from "react-i18next";
import { PortalIdentityQrCard } from "./PortalIdentityQrCard";

export function PortalStationQrPage() {
  const { t } = useTranslation("portal");

  return (
    <div className="mx-auto flex w-full max-w-lg flex-col gap-6 px-4 py-6">
      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.nav_station_qr", "QR estació")}
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            "employee_portal.station_qr.subtitle",
            "Mostra aquest QR al lector de la tablet per identificar-te i fitxar a l'estació.",
          )}
        </p>
        <p className="mt-3 text-sm">
          <Link
            href="/portal/punch"
            className="font-medium text-primary underline-offset-2 hover:underline"
          >
            {t("employee_portal.station_qr.back_to_punch", "Tornar al fitxatge")}
          </Link>
        </p>
      </div>

      <PortalIdentityQrCard />
    </div>
  );
}
