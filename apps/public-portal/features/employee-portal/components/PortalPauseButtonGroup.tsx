"use client";

import { Loader2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { PortalPauseConfig } from "../api/portalApi";
import { portalPauseLabel } from "../utils/portalPauseUtils";
import { getPortalPauseIcon } from "../utils/portalPauseIcons";

interface PortalPauseButtonGroupProps {
  configs: PortalPauseConfig[];
  loading: boolean;
  disabled?: boolean;
  onStartPause: (config: PortalPauseConfig) => void;
}

export function PortalPauseButtonGroup({
  configs,
  loading,
  disabled = false,
  onStartPause,
}: PortalPauseButtonGroupProps) {
  const { t, i18n } = useTranslation("portal");
  const lang = i18n.language?.slice(0, 2) ?? "ca";

  if (configs.length === 0) return null;

  return (
    <div className="space-y-2">
      <p className="text-muted-foreground text-center text-xs font-medium uppercase tracking-wide">
        {t("employee_portal.pause.choose_type", "Tipus de pausa")}
      </p>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {configs.map((config) => {
          const Icon = getPortalPauseIcon(config.key);
          return (
            <button
              key={config.id}
              type="button"
              disabled={loading || disabled}
              onClick={() => onStartPause(config)}
              className="flex flex-col items-center justify-center gap-2 rounded-xl border bg-background px-3 py-4 text-sm font-medium shadow-sm transition hover:border-amber-300 hover:bg-amber-50/80 active:scale-[0.98] disabled:opacity-60 dark:hover:bg-amber-950/20"
            >
              {loading ? (
                <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" aria-hidden />
              ) : (
                <span className="flex h-11 w-11 items-center justify-center rounded-full bg-amber-100 text-amber-800 dark:bg-amber-950/50 dark:text-amber-200">
                  <Icon className="h-6 w-6" strokeWidth={2} aria-hidden />
                </span>
              )}
              <span className="text-center leading-tight">{portalPauseLabel(config, lang)}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
