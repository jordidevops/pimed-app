"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslation } from "react-i18next";
import { ChevronLeft, ChevronRight, Loader2, MapPin, Moon } from "lucide-react";
import {
  fetchPortalMyShifts,
  PortalApiError,
  type PortalMyShiftSlot,
} from "../api/portalApi";
import {
  addDaysIso,
  formatWeekPeriodLabel,
  monthRange,
  startOfWeekIso,
  weekRange,
} from "../utils/scheduleUtils";
import { getPortalCalendarAnchor, getPortalTodayIso } from "../utils/portalDateUtils";

type ShiftsView = "week" | "month";

const FALLBACK_MONTHS = [
  "Gener", "Febrer", "Març", "Abril", "Maig", "Juny",
  "Juliol", "Agost", "Setembre", "Octubre", "Novembre", "Desembre",
];

function timeLabel(slot: PortalMyShiftSlot, overnightSuffix: string): string {
  const base = `${slot.start_time}–${slot.end_time}`;
  return slot.spans_midnight ? `${base}${overnightSuffix}` : base;
}

function groupSlotsByDate(slots: PortalMyShiftSlot[]): Map<string, PortalMyShiftSlot[]> {
  const map = new Map<string, PortalMyShiftSlot[]>();
  for (const slot of slots) {
    const list = map.get(slot.slot_date) ?? [];
    list.push(slot);
    map.set(slot.slot_date, list);
  }
  return map;
}

export function PortalMyShiftsPage() {
  const { t, i18n } = useTranslation("portal");
  const router = useRouter();
  const searchParams = useSearchParams();
  const todayIso = getPortalTodayIso();
  const dateParam = searchParams.get("date");

  const [view, setView] = useState<ShiftsView>("week");
  const [year, setYear] = useState(() => getPortalCalendarAnchor().year);
  const [month, setMonth] = useState(() => getPortalCalendarAnchor().month);
  const [weekStart, setWeekStart] = useState(() =>
    startOfWeekIso(dateParam && /^\d{4}-\d{2}-\d{2}$/.test(dateParam)
      ? dateParam
      : getPortalCalendarAnchor().todayIso),
  );
  const [slots, setSlots] = useState<PortalMyShiftSlot[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const monthNames = useMemo(() => {
    const raw = t("employee_portal.schedule.months", {
      returnObjects: true,
      defaultValue: FALLBACK_MONTHS,
    });
    return Array.isArray(raw) ? (raw as string[]) : FALLBACK_MONTHS;
  }, [t, i18n.language]);

  const { from, to } = useMemo(() => {
    if (view === "week") {
      const wr = weekRange(weekStart);
      return { from: wr.from, to: wr.to };
    }
    return monthRange(year, month);
  }, [view, weekStart, year, month]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalMyShifts(from, to);
      setSlots(data.slots ?? []);
    } catch (err) {
      if (err instanceof PortalApiError && err.code === "missing_session") {
        router.replace("/portal/expired");
        return;
      }
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.shifts.error_load_failed", "No s'han pogut carregar els torns"),
      );
    } finally {
      setLoading(false);
    }
  }, [from, to, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  const byDate = useMemo(() => groupSlotsByDate(slots), [slots]);
  const overnightSuffix = t("employee_portal.schedule.overnight_suffix", " (+1)");

  const periodLabel =
    view === "week"
      ? formatWeekPeriodLabel(weekStart, i18n.language, monthNames)
      : `${monthNames[month - 1] ?? month} ${year}`;

  return (
    <div className="mx-auto flex w-full max-w-lg flex-col gap-4 px-4 py-6">
      <header className="space-y-1">
        <h1 className="text-xl font-semibold text-foreground">
          {t("employee_portal.shifts.title", "Els meus torns")}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t("employee_portal.shifts.subtitle", "Torns publicats assignats a tu")}
        </p>
      </header>

      <div className="flex items-center justify-between gap-2">
        <div className="inline-flex rounded-lg border border-border p-0.5 text-xs">
          <button
            type="button"
            className={`rounded-md px-3 py-1.5 ${view === "week" ? "bg-foreground text-background" : ""}`}
            onClick={() => setView("week")}
          >
            {t("employee_portal.schedule.view_week", "Setmana")}
          </button>
          <button
            type="button"
            className={`rounded-md px-3 py-1.5 ${view === "month" ? "bg-foreground text-background" : ""}`}
            onClick={() => setView("month")}
          >
            {t("employee_portal.schedule.view_month", "Mes")}
          </button>
        </div>

        <div className="flex items-center gap-1">
          <button
            type="button"
            className="rounded-md p-2 hover:bg-muted"
            aria-label={t("employee_portal.shifts.prev", "Anterior")}
            onClick={() => {
              if (view === "week") setWeekStart((w) => addDaysIso(w, -7));
              else if (month === 1) {
                setMonth(12);
                setYear((y) => y - 1);
              } else setMonth((m) => m - 1);
            }}
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <span className="min-w-[8rem] text-center text-sm font-medium">{periodLabel}</span>
          <button
            type="button"
            className="rounded-md p-2 hover:bg-muted"
            aria-label={t("employee_portal.shifts.next", "Següent")}
            onClick={() => {
              if (view === "week") setWeekStart((w) => addDaysIso(w, 7));
              else if (month === 12) {
                setMonth(1);
                setYear((y) => y + 1);
              } else setMonth((m) => m + 1);
            }}
          >
            <ChevronRight className="h-4 w-4" />
          </button>
        </div>
      </div>

      <button
        type="button"
        className="self-start text-xs text-primary underline-offset-2 hover:underline"
        onClick={() => {
          setView("week");
          setWeekStart(startOfWeekIso(todayIso));
          const anchor = getPortalCalendarAnchor();
          setYear(anchor.year);
          setMonth(anchor.month);
        }}
      >
        {t("employee_portal.schedule.today", "Avui")}
      </button>

      {loading ? (
        <div className="flex items-center justify-center gap-2 py-12 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.shifts.loading", "Carregant torns…")}
        </div>
      ) : error ? (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      ) : slots.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
          {t("employee_portal.shifts.empty", "No tens torns publicats en aquest període")}
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          {[...byDate.entries()].map(([date, daySlots]) => (
            <section key={date} className="rounded-lg border border-border overflow-hidden">
              <div className="border-b border-border bg-muted/40 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                {date}
                {date === todayIso ? (
                  <span className="ml-2 normal-case font-medium text-sky-600">
                    {t("employee_portal.schedule.today", "Avui")}
                  </span>
                ) : null}
              </div>
              <ul className="divide-y divide-border">
                {daySlots.map((slot) => (
                  <li key={slot.id} className="flex items-start gap-3 px-3 py-3">
                    <span
                      className="mt-1 h-3 w-3 shrink-0 rounded-full"
                      style={{ backgroundColor: slot.shift_color ?? "#6366f1" }}
                      aria-hidden
                    />
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium text-foreground">{slot.shift_name}</p>
                      <p className="text-xs text-muted-foreground flex items-center gap-1.5">
                        {timeLabel(slot, overnightSuffix)}
                        {slot.spans_midnight ? <Moon className="h-3 w-3" /> : null}
                      </p>
                      {slot.location_name ? (
                        <p className="mt-1 flex items-center gap-1 text-xs text-muted-foreground">
                          <MapPin className="h-3 w-3 shrink-0" />
                          <span className="truncate">{slot.location_name}</span>
                        </p>
                      ) : null}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
