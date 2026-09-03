"use client";

import { Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { PortalPauseConfig } from "../api/portalApi";
import { portalPauseLabel } from "../utils/portalPauseUtils";
import { getPortalPauseIcon, PORTAL_PUNCH_HERO_CLASS } from "../utils/portalPauseIcons";

interface PortalPauseActiveButtonProps {
  activePauseType: string;
  configs: PortalPauseConfig[];
  loading: boolean;
  onEndPause: () => void;
}

export function PortalPauseActiveButton({
  activePauseType,
  configs,
  loading,
  onEndPause,
}: PortalPauseActiveButtonProps) {
  const { t, i18n } = useTranslation("portal");
  const lang = i18n.language?.slice(0, 2) ?? "ca";

  const active = configs.find((c) => c.key === activePauseType);
  const label = active ? portalPauseLabel(active, lang) : activePauseType;
  const Icon = getPortalPauseIcon(activePauseType);

  return (
    <button
      type="button"
      disabled={loading}
      onClick={onEndPause}
      className={`flex ${PORTAL_PUNCH_HERO_CLASS} flex-col items-center justify-center gap-2 rounded-full bg-amber-500 text-white shadow-lg transition hover:bg-amber-600 active:scale-[0.98] disabled:opacity-70`}
      aria-label={t("employee_portal.pause.end", "Tancar pausa")}
    >
      {loading ? (
        <Loader2 className="h-12 w-12 animate-spin" aria-hidden />
      ) : (
        <>
          <Icon className="h-14 w-14" strokeWidth={1.75} aria-hidden />
          <span className="max-w-[9rem] text-center text-base font-bold leading-tight">{label}</span>
          <span className="text-sm font-medium opacity-90">
            {t("employee_portal.pause.tap_to_end", "Toca per tornar")}
          </span>
        </>
      )}
    </button>
  );
}
