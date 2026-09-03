"use client";

import { LogIn, LogOut, PauseCircle, Car, Flag, PlayCircle, MapPin } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { PortalPunch } from "../api/portalApi";
import { formatPortalTime, PORTAL_TIMELINE_I18N, type PortalPunchType } from "../utils/punchStatus";
import { getPortalPauseIcon } from "../utils/portalPauseIcons";

interface PortalDailyTimelineProps {
  punches: PortalPunch[];
}

function punchLabel(punch: PortalPunch, t: (key: string, fallback: string) => string): string {
  const key = PORTAL_TIMELINE_I18N[punch.punch_type as PortalPunchType];
  if (key) return t(key, punch.punch_type);
  return punch.punch_type;
}

function PunchIcon({ punch }: { punch: PortalPunch }) {
  switch (punch.punch_type) {
    case "in":
      return <LogIn className="h-4 w-4 text-emerald-600" aria-hidden />;
    case "out":
      return <LogOut className="h-4 w-4 text-slate-500" aria-hidden />;
    case "break_start": {
      const Icon = punch.pause_type ? getPortalPauseIcon(punch.pause_type) : PauseCircle;
      return <Icon className="h-4 w-4 text-amber-600" aria-hidden />;
    }
    case "break_end":
      return <PauseCircle className="h-4 w-4 text-amber-500" aria-hidden />;
    case "day_start":
      return <PlayCircle className="h-4 w-4 text-sky-600" aria-hidden />;
    case "day_end":
      return <Flag className="h-4 w-4 text-slate-600" aria-hidden />;
    case "travel_start":
      return <Car className="h-4 w-4 text-violet-600" aria-hidden />;
    case "travel_end":
      return <MapPin className="h-4 w-4 text-violet-600" aria-hidden />;
    default:
      return null;
  }
}

function dotColor(punchType: string): string {
  switch (punchType) {
    case "in":
      return "bg-emerald-500";
    case "break_start":
    case "break_end":
      return "bg-amber-500";
    case "day_start":
      return "bg-sky-500";
    case "travel_start":
    case "travel_end":
      return "bg-violet-500";
    case "day_end":
      return "bg-slate-500";
    default:
      return "bg-slate-400";
  }
}

export function PortalDailyTimeline({ punches }: PortalDailyTimelineProps) {
  const { t } = useTranslation("portal");

  if (punches.length === 0) {
    return (
      <p className="text-muted-foreground py-6 text-center text-sm">
        {t("employee_portal.timeline_empty", "Encara no hi ha fitxatges avui")}
      </p>
    );
  }

  return (
    <div className="space-y-2">
      <h2 className="text-muted-foreground text-sm font-semibold uppercase tracking-wide">
        {t("employee_portal.timeline_title", "Avui")}
      </h2>
      <ol className="relative ml-3 space-y-3 border-l border-border">
        {punches.map((punch) => (
          <li key={punch.id} className="ml-4">
            <span
              className={`absolute -left-1.5 flex h-3 w-3 rounded-full border-2 border-background ${dotColor(punch.punch_type)}`}
              aria-hidden
            />
            <div className="flex items-center gap-2 text-sm">
              <PunchIcon punch={punch} />
              <span className="font-medium">{punchLabel(punch, t)}</span>
              {punch.pending && (
                <span className="text-muted-foreground text-xs">
                  ({t("employee_portal.timeline_pending", "pendent")})
                </span>
              )}
              <span className="text-muted-foreground tabular-nums">
                {formatPortalTime(punch.occurred_at)}
              </span>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}
