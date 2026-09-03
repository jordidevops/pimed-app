"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  fetchStationEmployeeHistory,
  type StationHistoryDay,
  type StationHistoryPunch,
} from "@/lib/attendance-station/client";
import {
  formatStationHistoryTime,
  formatStationNetMinutes,
  getStationHistoryRange,
  mergeStationHistoryDays,
  navigateStationHistory,
  type StationHistoryViewMode,
} from "@/lib/attendance-station/stationHistoryUtils";

type Props = {
  employeeId: string;
  employeeName: string;
  maxDays: number;
  unlockedPin: string;
  busy?: boolean;
  onBack: () => void;
  onInteract: () => void;
  onEndSession: () => void;
};

function statusLabel(status: string): string {
  switch (status) {
    case "closed":
      return "Tancat";
    case "open":
      return "Obert";
    case "missing":
      return "Sense dades";
    case "adjusted":
      return "Ajustat";
    default:
      return status;
  }
}

export function StationEmployeeHistoryView({
  employeeId,
  employeeName,
  maxDays,
  unlockedPin,
  busy = false,
  onBack,
  onInteract,
  onEndSession,
}: Props) {
  const [mode, setMode] = useState<StationHistoryViewMode>("week");
  const [refDate, setRefDate] = useState(() => new Date());
  const [days, setDays] = useState<StationHistoryDay[]>([]);
  const [timeZone, setTimeZone] = useState("Europe/Madrid");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const range = useMemo(() => getStationHistoryRange(mode, refDate), [mode, refDate]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchStationEmployeeHistory({
        employeeId,
        from: range.from,
        to: range.to,
        pin: unlockedPin,
      });
      setTimeZone(data.site_timezone || "Europe/Madrid");
      setDays(
        mergeStationHistoryDays(
          (data.entries ?? []) as StationHistoryDay[],
          (data.punches ?? []) as StationHistoryPunch[],
          data.site_timezone || "Europe/Madrid",
        ),
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : "station_history_failed";
      if (message.includes("station_history_range_too_large")) {
        setError(`El període supera el màxim de ${maxDays} dies configurat a l'estació.`);
      } else if (message.includes("station_history_disabled")) {
        setError("L'historial no està habilitat en aquesta estació.");
      } else {
        setError("No s'ha pogut carregar l'historial.");
      }
      setDays([]);
    } finally {
      setLoading(false);
    }
  }, [employeeId, maxDays, range.from, range.to, unlockedPin]);

  useEffect(() => {
    void load();
  }, [load]);

  const totalNet = days.reduce((sum, day) => sum + (day.net_minutes ?? 0), 0);

  return (
    <div
      className="space-y-4"
      onPointerDown={onInteract}
      onKeyDown={onInteract}
    >
      <div className="flex flex-wrap items-start justify-between gap-3 rounded-2xl border p-4">
        <div>
          <p className="text-sm text-muted-foreground">Els meus fitxatges</p>
          <h2 className="text-2xl font-semibold">{employeeName}</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Només lectura · màx. {maxDays} dies
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            className="rounded-xl border px-4 py-3 text-sm font-medium hover:bg-muted"
            onClick={onBack}
            disabled={busy}
          >
            Tornar a fitxar
          </button>
          <button
            type="button"
            className="rounded-xl border px-4 py-3 text-sm font-medium hover:bg-muted"
            onClick={onEndSession}
          >
            Tancar sessió
          </button>
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-2">
          {(["week", "month"] as const).map((option) => (
            <button
              key={option}
              type="button"
              className={`rounded-xl px-3 py-2 text-sm font-medium ${
                mode === option ? "bg-primary text-primary-foreground" : "border hover:bg-muted"
              }`}
              onClick={() => setMode(option)}
            >
              {option === "week" ? "Setmana" : "Mes"}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            className="rounded-xl border px-3 py-2 text-sm hover:bg-muted"
            onClick={() => setRefDate((prev) => navigateStationHistory(mode, prev, -1))}
          >
            ←
          </button>
          <span className="min-w-[10rem] text-center text-sm font-medium">{range.label}</span>
          <button
            type="button"
            className="rounded-xl border px-3 py-2 text-sm hover:bg-muted"
            onClick={() => setRefDate((prev) => navigateStationHistory(mode, prev, 1))}
          >
            →
          </button>
        </div>
      </div>

      {error ? (
        <p className="rounded-xl border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      {loading ? (
        <p className="text-sm text-muted-foreground">Carregant historial…</p>
      ) : days.length === 0 ? (
        <p className="rounded-xl border border-dashed p-6 text-center text-sm text-muted-foreground">
          Cap fitxatge en aquest període.
        </p>
      ) : (
        <div className="space-y-2">
          <p className="text-sm text-muted-foreground">
            Total net: {formatStationNetMinutes(totalNet)}
          </p>
          <ul className="divide-y rounded-2xl border">
            {days.map((day) => (
              <li key={day.id} className="flex items-center justify-between gap-3 px-4 py-3">
                <div>
                  <p className="font-medium">
                    {new Date(`${day.work_date}T12:00:00`).toLocaleDateString("ca-ES", {
                      weekday: "short",
                      day: "numeric",
                      month: "short",
                    })}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {formatStationHistoryTime(day.starts_at, timeZone)} –{" "}
                    {formatStationHistoryTime(day.ends_at, timeZone)} · {statusLabel(day.status)}
                  </p>
                </div>
                <p className="text-sm font-medium tabular-nums">
                  {formatStationNetMinutes(day.net_minutes)}
                </p>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
