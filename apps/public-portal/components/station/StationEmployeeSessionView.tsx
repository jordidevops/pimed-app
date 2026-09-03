"use client";

import {
  stationBlockedMessage,
  stationDayStateLabel,
  type StationDayState,
} from "@/lib/attendance-station/punchUi";
import type { StationPauseConfig } from "@/lib/attendance-station/client";
import type { StationSessionEmployee } from "@/lib/attendance-station/useStationSession";

function pauseLabel(config: StationPauseConfig): string {
  const labels = config.label_i18n;
  if (labels) {
    return labels.ca || labels.es || labels.en || Object.values(labels)[0] || config.key;
  }
  return config.key;
}

type Props = {
  employee: StationSessionEmployee;
  phase: "employee_session" | "success_flash";
  flashMessage: string | null;
  countdownRemaining: number | null;
  countdownTotal: number;
  busy: boolean;
  error: string | null;
  allowHistory: boolean;
  pauseConfigs: StationPauseConfig[];
  onEndSession: () => void;
  onPunch: (punchType: "in" | "out" | "break_start" | "break_end", pauseType?: string) => void;
  onOpenHistory: () => void;
  onInteract: () => void;
};

export function StationEmployeeSessionView({
  employee,
  phase,
  flashMessage,
  countdownRemaining,
  countdownTotal,
  busy,
  error,
  allowHistory,
  pauseConfigs,
  onEndSession,
  onPunch,
  onOpenHistory,
  onInteract,
}: Props) {
  const nextPunch = employee.next_punch ?? null;
  const dayState = (employee.day_state ?? null) as StationDayState | null;
  const canStartPause = Boolean(employee.can_start_pause ?? dayState === "work");
  const canEndPause = Boolean(employee.can_end_pause ?? dayState === "break");
  const progress =
    phase === "success_flash" && countdownRemaining !== null && countdownTotal > 0
      ? Math.max(0, Math.min(1, countdownRemaining / countdownTotal))
      : 0;

  return (
    <div
      className="space-y-4"
      onPointerDown={onInteract}
      onKeyDown={onInteract}
    >
      <div className="flex flex-wrap items-start justify-between gap-3 rounded-2xl border p-4">
        <div>
          <p className="text-sm text-muted-foreground">Sessió activa</p>
          <h2 className="text-2xl font-semibold">{employee.full_name}</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {stationDayStateLabel(dayState)}
          </p>
        </div>
        <button
          type="button"
          className="rounded-xl border px-4 py-3 text-sm font-medium hover:bg-muted"
          onClick={onEndSession}
        >
          Tancar sessió
        </button>
      </div>

      {phase === "success_flash" && flashMessage ? (
        <div className="space-y-2 rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
          <p className="text-sm font-medium text-emerald-900">{flashMessage}</p>
          {countdownRemaining !== null ? (
            <>
              <p className="text-xs text-emerald-800">
                Tornada a espera en {countdownRemaining}s — toca per continuar a la sessió
              </p>
              <div className="h-2 overflow-hidden rounded-full bg-emerald-200/80">
                <div
                  className="h-full rounded-full bg-emerald-600 transition-[width] duration-1000 linear"
                  style={{ width: `${progress * 100}%` }}
                />
              </div>
            </>
          ) : null}
        </div>
      ) : null}

      {error ? (
        <p className="rounded-xl border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      {employee.wrong_scheduled_location && employee.warn_wrong_scheduled_location !== false ? (
        <p className="rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
          Avui et tocava a{" "}
          <span className="font-medium">
            {employee.scheduled_location_path
              || employee.scheduled_location_name
              || "una altra ubicació"}
          </span>
          . Pots continuar fitxant aquí; el sistema ho marcarà com a avís.
        </p>
      ) : null}

      {employee.outside_assignment && employee.warn_unassigned_punch !== false ? (
        <p className="rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
          No estàs assignat a aquesta ubicació. Pots continuar fitxant; el sistema ho marcarà com a avís.
        </p>
      ) : null}

      {nextPunch === "in" ? (
        <button
          type="button"
          disabled={busy}
          onClick={() => onPunch("in")}
          className="w-full rounded-xl bg-emerald-600 px-4 py-5 text-xl font-semibold text-white disabled:opacity-50"
        >
          Registrar entrada
        </button>
      ) : null}

      {canEndPause ? (
        <button
          type="button"
          disabled={busy}
          onClick={() => onPunch("break_end", employee.active_pause_type ?? undefined)}
          className="w-full rounded-xl bg-amber-600 px-4 py-5 text-xl font-semibold text-white disabled:opacity-50"
        >
          Tancar pausa
        </button>
      ) : null}

      {nextPunch === "out" ? (
        <button
          type="button"
          disabled={busy}
          onClick={() => onPunch("out")}
          className="w-full rounded-xl bg-slate-800 px-4 py-5 text-xl font-semibold text-white disabled:opacity-50"
        >
          Registrar sortida
        </button>
      ) : null}

      {canStartPause && pauseConfigs.length > 0 ? (
        <div className="space-y-2">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Iniciar pausa
          </p>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
            {pauseConfigs.map((config) => (
              <button
                key={config.id}
                type="button"
                disabled={busy}
                onClick={() => onPunch("break_start", config.key)}
                className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-4 text-sm font-medium text-amber-950 hover:bg-amber-100 disabled:opacity-50"
              >
                {pauseLabel(config)}
              </button>
            ))}
          </div>
        </div>
      ) : null}

      {!nextPunch && !canEndPause ? (
        <p className="rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          {stationBlockedMessage(dayState)}
        </p>
      ) : null}

      {allowHistory ? (
        <button
          type="button"
          className="w-full rounded-xl border px-4 py-3 text-sm font-medium hover:bg-muted"
          onClick={onOpenHistory}
        >
          Veure historial
        </button>
      ) : null}
    </div>
  );
}
