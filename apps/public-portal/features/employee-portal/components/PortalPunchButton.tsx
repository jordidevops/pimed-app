"use client";

import { Loader2, LogIn, LogOut } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { PortalPunchStatus } from "../utils/punchStatus";
import { nextPortalPunchAction } from "../utils/punchStatus";
import { PORTAL_PUNCH_HERO_CLASS } from "../utils/portalPauseIcons";

interface PortalPunchButtonProps {
  status: PortalPunchStatus;
  loading: boolean;
  onPunchIn: () => void;
  onPunchOut: () => void;
}

export function PortalPunchButton({
  status,
  loading,
  onPunchIn,
  onPunchOut,
}: PortalPunchButtonProps) {
  const { t } = useTranslation("portal");
  const action = nextPortalPunchAction(status);

  if (status === "on_pause") {
    return null;
  }

  if (action === null) return null;

  const isIn = action === "in";

  return (
    <button
      type="button"
      disabled={loading}
      onClick={isIn ? onPunchIn : onPunchOut}
      className={`flex ${PORTAL_PUNCH_HERO_CLASS} flex-col items-center justify-center gap-3 rounded-full text-lg font-bold shadow-lg transition active:scale-[0.98] disabled:opacity-70 ${
        isIn
          ? "bg-emerald-600 text-white hover:bg-emerald-700"
          : "bg-slate-600 text-white hover:bg-slate-700"
      }`}
      aria-label={
        isIn
          ? t("employee_portal.punch_in", "Registrar entrada")
          : t("employee_portal.punch_out", "Registrar sortida")
      }
    >
      {loading ? (
        <Loader2 className="h-12 w-12 animate-spin" aria-hidden />
      ) : isIn ? (
        <>
          <LogIn className="h-12 w-12" aria-hidden />
          {t("employee_portal.punch_in_short", "Entrar")}
        </>
      ) : (
        <>
          <LogOut className="h-12 w-12" aria-hidden />
          {t("employee_portal.punch_out_short", "Sortir")}
        </>
      )}
    </button>
  );
}
