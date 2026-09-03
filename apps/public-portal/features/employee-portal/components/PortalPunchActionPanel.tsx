"use client";

import { Loader2, LogIn, LogOut, Car, Flag, PlayCircle, MapPin } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { PortalPunchDayState, PortalPunchStatus, PortalPunchType } from "../utils/punchStatus";
import {
  getPrimaryPortalPunchAction,
  getSecondaryPortalPunchActions,
  PORTAL_PUNCH_I18N,
} from "../utils/punchStatus";
import {
  PORTAL_PUNCH_HERO_CLASS,
  PORTAL_PUNCH_SECONDARY_SLOT_CLASS,
} from "../utils/portalPauseIcons";

interface PortalPunchActionPanelProps {
  status: PortalPunchStatus;
  dayState: PortalPunchDayState;
  isMobileProfile: boolean;
  legacyInOutOnly: boolean;
  loadingType: PortalPunchType | null;
  onPunch: (type: PortalPunchType) => void;
}

function PunchTypeIcon({ type, className }: { type: PortalPunchType; className?: string }) {
  const cn = className ?? "h-12 w-12";
  switch (type) {
    case "in":
      return <LogIn className={cn} aria-hidden />;
    case "out":
      return <LogOut className={cn} aria-hidden />;
    case "day_start":
      return <PlayCircle className={cn} aria-hidden />;
    case "day_end":
      return <Flag className={cn} aria-hidden />;
    case "travel_start":
      return <Car className={cn} aria-hidden />;
    case "travel_end":
      return <MapPin className={cn} aria-hidden />;
    default:
      return null;
  }
}

function heroClass(type: PortalPunchType): string {
  switch (type) {
    case "in":
      return "bg-emerald-600 text-white hover:bg-emerald-700";
    case "out":
    case "day_end":
      return "bg-slate-600 text-white hover:bg-slate-700";
    case "day_start":
      return "bg-sky-600 text-white hover:bg-sky-700";
    case "travel_start":
    case "travel_end":
      return "bg-violet-600 text-white hover:bg-violet-700";
    default:
      return "bg-primary text-primary-foreground";
  }
}

export function PortalPunchActionPanel({
  status,
  dayState,
  isMobileProfile,
  legacyInOutOnly,
  loadingType,
  onPunch,
}: PortalPunchActionPanelProps) {
  const { t } = useTranslation("portal");

  if (status === "on_pause") return null;

  const primary = getPrimaryPortalPunchAction(dayState, isMobileProfile, legacyInOutOnly);
  if (!primary) return null;

  const secondary = getSecondaryPortalPunchActions(dayState, isMobileProfile, legacyInOutOnly);
  const labels = PORTAL_PUNCH_I18N[primary];
  const isLoading = loadingType !== null;

  return (
    <div className="flex w-full max-w-sm flex-col items-center">
      <div className={`flex shrink-0 ${PORTAL_PUNCH_HERO_CLASS} items-center justify-center`}>
        <button
          type="button"
          disabled={isLoading}
          onClick={() => onPunch(primary)}
          className={`flex ${PORTAL_PUNCH_HERO_CLASS} flex-col items-center justify-center gap-3 rounded-full text-lg font-bold shadow-lg transition active:scale-[0.98] disabled:opacity-70 ${heroClass(primary)}`}
          aria-label={t(labels.confirm, labels.shortDefault)}
        >
          {loadingType === primary ? (
            <Loader2 className="h-12 w-12 animate-spin" aria-hidden />
          ) : (
            <>
              <PunchTypeIcon type={primary} />
              {t(labels.short, labels.shortDefault)}
            </>
          )}
        </button>
      </div>

      <div
        className={`mt-4 flex w-full flex-wrap items-start justify-center gap-2 px-1 ${PORTAL_PUNCH_SECONDARY_SLOT_CLASS}`}
      >
        {secondary.map((type) => {
          const sec = PORTAL_PUNCH_I18N[type];
          return (
            <button
              key={type}
              type="button"
              disabled={isLoading}
              onClick={() => onPunch(type)}
              className="inline-flex items-center gap-1.5 rounded-md border border-border bg-background px-3 py-1.5 text-sm font-medium hover:bg-muted disabled:opacity-70"
              aria-label={t(sec.confirm, sec.shortDefault)}
            >
              {loadingType === type ? (
                <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
              ) : (
                <PunchTypeIcon type={type} className="h-4 w-4" />
              )}
              {t(sec.short, sec.shortDefault)}
            </button>
          );
        })}
      </div>
    </div>
  );
}
