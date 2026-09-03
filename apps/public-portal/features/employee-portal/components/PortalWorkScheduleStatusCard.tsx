"use client";

import { useMemo } from "react";
import { useTranslation } from "react-i18next";
import { AlertCircle, AlertTriangle, CheckCircle, Clock, Info } from "lucide-react";
import type { PortalPunch, PortalScheduleDay } from "../api/portalApi";
import type { PortalPunchStatus } from "../utils/punchStatus";
import { computeWorkScheduleStatus } from "../utils/workScheduleStatus";

interface PortalWorkScheduleStatusCardProps {
  schedule: PortalScheduleDay | null;
  punches: PortalPunch[];
  presenceStatus: PortalPunchStatus;
  className?: string;
}

const KIND_STYLES = {
  success: {
    border: "border-emerald-200",
    bg: "bg-emerald-50 dark:bg-emerald-950/20",
    title: "text-emerald-900 dark:text-emerald-100",
    icon: CheckCircle,
  },
  warning: {
    border: "border-amber-200",
    bg: "bg-amber-50 dark:bg-amber-950/20",
    title: "text-amber-900 dark:text-amber-100",
    icon: AlertTriangle,
  },
  error: {
    border: "border-red-200",
    bg: "bg-red-50 dark:bg-red-950/20",
    title: "text-red-900 dark:text-red-100",
    icon: AlertCircle,
  },
  info: {
    border: "border-sky-200",
    bg: "bg-sky-50 dark:bg-sky-950/20",
    title: "text-sky-900 dark:text-sky-100",
    icon: Info,
  },
} as const;

function formatScheduleDetail(day: PortalScheduleDay): string | undefined {
  if (!day.work_intervals?.length) return undefined;
  return day.work_intervals.map((i) => `${i.start}–${i.end}`).join(" · ");
}

function formatLastPunch(punch: PortalPunch | null, locale: string): string | null {
  if (!punch?.occurred_at) return null;
  const time = new Date(punch.occurred_at).toLocaleTimeString(locale, {
    hour: "2-digit",
    minute: "2-digit",
  });
  return `${time} · ${punch.punch_type}`;
}

export function PortalWorkScheduleStatusCard({
  schedule,
  punches,
  presenceStatus,
  className = "",
}: PortalWorkScheduleStatusCardProps) {
  const { t, i18n } = useTranslation("portal");

  const scheduleDetail = schedule ? formatScheduleDetail(schedule) : undefined;

  const status = useMemo(
    () =>
      computeWorkScheduleStatus({
        schedule: schedule
          ? {
              dayType: schedule.day_type,
              laborDayType: schedule.labor_day_type,
              intervals: schedule.work_intervals ?? [],
              holidayName: schedule.holiday_name,
              isHoliday: schedule.is_holiday,
              isAbsence: schedule.is_absence,
            }
          : null,
        punches,
        presenceStatus,
      }),
    [schedule, punches, presenceStatus],
  );

  const lastPunch = punches.length > 0 ? punches[punches.length - 1]! : null;
  const lastPunchLabel = formatLastPunch(lastPunch, i18n.language);

  if (!status) return null;

  const styles = KIND_STYLES[status.kind];
  const Icon = styles.icon;

  return (
    <div
      className={`rounded-xl border p-4 ${styles.border} ${styles.bg} ${className}`}
      role="status"
      aria-live="polite"
    >
      <div className="flex items-start gap-3">
        <Icon className={`mt-0.5 h-5 w-5 shrink-0 ${styles.title}`} aria-hidden />
        <div className="min-w-0 flex-1 space-y-1">
          <p className={`text-sm font-semibold ${styles.title}`}>
            {t(`employee_portal.${status.titleKey}`, status.titleDefault)}
          </p>
          <p className="text-sm text-foreground/80">
            {t(
              `employee_portal.${status.descriptionKey}`,
              status.descriptionDefault,
              status.descriptionParams,
            )}
          </p>
          {scheduleDetail && (
            <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <Clock className="h-3.5 w-3.5 shrink-0" aria-hidden />
              <span>{scheduleDetail}</span>
            </p>
          )}
          {lastPunchLabel && (
            <p className="text-xs text-muted-foreground">
              {t("employee_portal.work_status.last_punch", "Últim fitxatge")}: {lastPunchLabel}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
