"use client";

import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useSearchParams } from "next/navigation";
import {
  AlertTriangle,
  Download,
  LayoutList,
  Loader2,
  ShieldCheck,
  CalendarDays,
} from "lucide-react";
import { INSPECT_API_BASE } from "@/lib/inspection-access/constants";

interface InspectionPunch {
  id: string;
  punch_type: string;
  occurred_at: string;
  received_at: string | null;
  source: string | null;
  location_name_snapshot: string | null;
  device_name_snapshot: string | null;
  anomaly_codes: string[] | null;
  notes: string | null;
  pause_type: string | null;
}

interface InspectionSummary {
  work_date: string;
  expected_minutes: number | null;
  worked_minutes: number | null;
  overtime_minutes: number | null;
  day_type: string | null;
  summary_status: string | null;
  punch_count: number | null;
  needs_review: boolean | null;
  anomaly_codes: string[] | null;
  starts_at: string | null;
  ends_at: string | null;
  break_minutes: number | null;
  net_minutes: number | null;
  gross_minutes: number | null;
  entry_status: string | null;
  effective_work_minutes: number | null;
}

interface InspectionData {
  link_id: string;
  tenant_name: string;
  employee_id: string;
  employee_name: string;
  period_from: string;
  period_to: string;
  expires_at: string;
  include_consolidated?: boolean;
  punches: InspectionPunch[];
  punches_total: number;
  summaries: InspectionSummary[];
  summaries_total: number;
  format: string;
  generated_at: string;
}

type Phase = "loading" | "ready" | "invalid" | "error";
type MainTab = "punches" | "consolidated";
type PunchView = "timeline" | "table";

const PUNCHES_PAGE = 500;
const SUMMARIES_PAGE = 200;

const PUNCH_TYPE_LABELS: Record<string, string> = {
  in: "Entrada",
  out: "Sortida",
  day_start: "Inici jornada",
  day_end: "Fi jornada",
  break_start: "Inici pausa",
  break_end: "Fi pausa",
  travel_start: "Inici desplaçament",
  travel_end: "Fi desplaçament",
};

function punchTypeLabel(type: string): string {
  return PUNCH_TYPE_LABELS[type] ?? type;
}

function punchTone(type: string): string {
  if (type === "in" || type === "day_start") return "bg-emerald-500";
  if (type === "out" || type === "day_end") return "bg-slate-700";
  if (type.startsWith("break")) return "bg-amber-500";
  if (type.startsWith("travel")) return "bg-sky-500";
  return "bg-muted-foreground";
}

function formatDate(value: string | null | undefined): string {
  if (!value) return "";
  const d = new Date(value.length <= 10 ? `${value}T12:00:00` : value);
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleDateString("ca-ES", {
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

function formatDateTime(value: string | null | undefined): string {
  if (!value) return "";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleString("ca-ES");
}

function formatTime(value: string | null | undefined): string {
  if (!value) return "";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleTimeString("ca-ES", { hour: "2-digit", minute: "2-digit" });
}

function formatMinutes(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return "";
  const sign = value < 0 ? "-" : "";
  const abs = Math.abs(value);
  const h = Math.floor(abs / 60);
  const m = abs % 60;
  return `${sign}${h}h ${String(m).padStart(2, "0")}m`;
}

function dayKey(occurredAt: string): string {
  const d = new Date(occurredAt);
  if (Number.isNaN(d.getTime())) return occurredAt.slice(0, 10);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function csvEscape(value: unknown): string {
  const s = value == null ? "" : String(value);
  if (/[",\n;]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

function downloadBlob(filename: string, content: string, type: string): void {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

function PunchTimeline({ punches }: { punches: InspectionPunch[] }) {
  const byDay = useMemo(() => {
    const map = new Map<string, InspectionPunch[]>();
    for (const punch of punches) {
      const key = dayKey(punch.occurred_at);
      const list = map.get(key) ?? [];
      list.push(punch);
      map.set(key, list);
    }
    return Array.from(map.entries()).sort(([a], [b]) => a.localeCompare(b));
  }, [punches]);

  if (punches.length === 0) {
    return (
      <p className="rounded-lg border px-4 py-8 text-center text-sm text-muted-foreground">
        Cap fitxatge en aquest període.
      </p>
    );
  }

  return (
    <div className="space-y-6">
      {byDay.map(([day, dayPunches]) => (
        <section key={day} className="rounded-xl border bg-card overflow-hidden">
          <div className="flex items-center gap-2 border-b bg-muted/40 px-4 py-2.5">
            <CalendarDays className="h-4 w-4 text-muted-foreground" />
            <h3 className="text-sm font-semibold capitalize">{formatDate(day)}</h3>
            <span className="text-xs text-muted-foreground">
              {dayPunches.length} fitxatge{dayPunches.length === 1 ? "" : "s"}
            </span>
          </div>
          <ol className="relative px-4 py-4 space-y-0">
            {dayPunches.map((p, idx) => {
              const isLast = idx === dayPunches.length - 1;
              return (
                <li key={p.id} className="relative flex gap-4 pb-5 last:pb-0">
                  {!isLast ? (
                    <span
                      className="absolute left-[11px] top-6 bottom-0 w-px bg-border"
                      aria-hidden
                    />
                  ) : null}
                  <span
                    className={`relative z-10 mt-1 h-6 w-6 shrink-0 rounded-full ${punchTone(p.punch_type)} ring-4 ring-background`}
                    aria-hidden
                  />
                  <div className="min-w-0 flex-1 pt-0.5">
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
                      <time className="text-sm font-semibold tabular-nums">
                        {formatTime(p.occurred_at)}
                      </time>
                      <span className="text-sm font-medium">{punchTypeLabel(p.punch_type)}</span>
                      {p.pause_type ? (
                        <span className="text-xs text-muted-foreground">({p.pause_type})</span>
                      ) : null}
                    </div>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
                      {p.location_name_snapshot ? <span>{p.location_name_snapshot}</span> : null}
                      {p.device_name_snapshot ? <span>{p.device_name_snapshot}</span> : null}
                      {p.source ? <span className="uppercase tracking-wide">{p.source}</span> : null}
                    </div>
                    {(p.anomaly_codes?.length ?? 0) > 0 ? (
                      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">
                        {(p.anomaly_codes ?? []).join(", ")}
                      </p>
                    ) : null}
                    {p.notes ? (
                      <p className="mt-1 text-xs text-muted-foreground italic">{p.notes}</p>
                    ) : null}
                  </div>
                </li>
              );
            })}
          </ol>
        </section>
      ))}
    </div>
  );
}

function InspectPageInner() {
  const params = useParams<{ id: string }>();
  const searchParams = useSearchParams();
  const linkId = params.id;

  const [phase, setPhase] = useState<Phase>("loading");
  const [data, setData] = useState<InspectionData | null>(null);
  const [loadingMorePunches, setLoadingMorePunches] = useState(false);
  const [loadingMoreSummaries, setLoadingMoreSummaries] = useState(false);
  const [mainTab, setMainTab] = useState<MainTab>("punches");
  const [punchView, setPunchView] = useState<PunchView>("timeline");
  const startedRef = useRef(false);

  const fetchPage = useCallback(
    async (punchesOffset: number, summariesOffset: number): Promise<InspectionData | null> => {
      const qs = new URLSearchParams({
        punches_offset: String(punchesOffset),
        punches_limit: String(PUNCHES_PAGE),
        summaries_offset: String(summariesOffset),
        summaries_limit: String(SUMMARIES_PAGE),
      });
      const res = await fetch(`${INSPECT_API_BASE}/data?${qs.toString()}`, {
        method: "GET",
        cache: "no-store",
        credentials: "include",
      });
      if (!res.ok) {
        if (res.status === 404 || res.status === 401) {
          setPhase("invalid");
          return null;
        }
        setPhase("error");
        return null;
      }
      return (await res.json()) as InspectionData;
    },
    [],
  );

  const bootstrap = useCallback(async () => {
    const secret = searchParams.get("t");

    if (secret) {
      try {
        const res = await fetch(`${INSPECT_API_BASE}/session`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ link_id: linkId, secret }),
          credentials: "include",
        });
        if (!res.ok) {
          setPhase("invalid");
          return;
        }
        if (typeof window !== "undefined") {
          window.history.replaceState(null, "", `/inspect/${linkId}`);
        }
      } catch {
        setPhase("error");
        return;
      }
    }

    const payload = await fetchPage(0, 0);
    if (payload) {
      setData(payload);
      setPhase("ready");
      if (payload.include_consolidated === false) {
        setMainTab("punches");
      }
    }
  }, [fetchPage, linkId, searchParams]);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;
    void bootstrap();
  }, [bootstrap]);

  async function handleLoadMorePunches() {
    if (!data) return;
    setLoadingMorePunches(true);
    try {
      const payload = await fetchPage(data.punches.length, 0);
      if (payload) {
        setData((prev) =>
          prev
            ? { ...prev, punches: [...prev.punches, ...payload.punches], punches_total: payload.punches_total }
            : prev,
        );
      }
    } finally {
      setLoadingMorePunches(false);
    }
  }

  async function handleLoadMoreSummaries() {
    if (!data) return;
    setLoadingMoreSummaries(true);
    try {
      const payload = await fetchPage(0, data.summaries.length);
      if (payload) {
        setData((prev) =>
          prev
            ? {
                ...prev,
                summaries: [...prev.summaries, ...payload.summaries],
                summaries_total: payload.summaries_total,
              }
            : prev,
        );
      }
    } finally {
      setLoadingMoreSummaries(false);
    }
  }

  function handleDownloadJson() {
    if (!data) return;
    downloadBlob(
      `registre-horari-${data.employee_name || data.employee_id}.json`,
      JSON.stringify(data, null, 2),
      "application/json",
    );
  }

  function handleDownloadPunchesCsv() {
    if (!data) return;
    const header = [
      "punch_type",
      "occurred_at",
      "received_at",
      "source",
      "location",
      "device",
      "pause_type",
      "anomaly_codes",
      "notes",
    ];
    const rows = data.punches.map((p) =>
      [
        p.punch_type,
        p.occurred_at,
        p.received_at ?? "",
        p.source ?? "",
        p.location_name_snapshot ?? "",
        p.device_name_snapshot ?? "",
        p.pause_type ?? "",
        (p.anomaly_codes ?? []).join(" "),
        p.notes ?? "",
      ]
        .map(csvEscape)
        .join(","),
    );
    downloadBlob(
      `fitxatges-${data.employee_name || data.employee_id}.csv`,
      [header.join(","), ...rows].join("\n"),
      "text/csv;charset=utf-8",
    );
  }

  function handleDownloadSummariesCsv() {
    if (!data) return;
    const header = [
      "work_date",
      "day_type",
      "expected_minutes",
      "worked_minutes",
      "effective_work_minutes",
      "overtime_minutes",
      "break_minutes",
      "starts_at",
      "ends_at",
      "status",
      "anomaly_codes",
    ];
    const rows = data.summaries.map((s) =>
      [
        s.work_date,
        s.day_type ?? "",
        s.expected_minutes ?? "",
        s.worked_minutes ?? "",
        s.effective_work_minutes ?? "",
        s.overtime_minutes ?? "",
        s.break_minutes ?? "",
        s.starts_at ?? "",
        s.ends_at ?? "",
        s.summary_status ?? "",
        (s.anomaly_codes ?? []).join(" "),
      ]
        .map(csvEscape)
        .join(","),
    );
    downloadBlob(
      `consolidat-${data.employee_name || data.employee_id}.csv`,
      [header.join(","), ...rows].join("\n"),
      "text/csv;charset=utf-8",
    );
  }

  if (phase === "loading") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center text-sm text-muted-foreground">
        <Loader2 className="mx-auto mb-3 h-6 w-6 animate-spin" />
        Obrint el registre…
      </div>
    );
  }

  if (phase === "invalid") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center">
        <AlertTriangle className="mx-auto mb-3 h-8 w-8 text-amber-500" />
        <h1 className="text-xl font-semibold">Enllaç no vàlid o caducat</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Aquest enllaç d&apos;inspecció ha caducat, s&apos;ha revocat o no és correcte. Demana un enllaç
          nou a l&apos;empresa.
        </p>
      </div>
    );
  }

  if (phase === "error" || !data) {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center">
        <AlertTriangle className="mx-auto mb-3 h-8 w-8 text-destructive" />
        <h1 className="text-xl font-semibold">No s&apos;ha pogut carregar el registre</h1>
        <p className="mt-2 text-sm text-muted-foreground">Torna-ho a provar més tard.</p>
      </div>
    );
  }

  const showConsolidated = data.include_consolidated !== false;
  const punchesRemaining = data.punches_total - data.punches.length;
  const summariesRemaining = data.summaries_total - data.summaries.length;

  return (
    <div className="mx-auto max-w-5xl px-4 py-8 space-y-6">
      <header className="space-y-3">
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <ShieldCheck className="h-4 w-4" />
          Accés d&apos;inspecció · només lectura
        </div>
        <h1 className="text-2xl font-semibold">Registre horari</h1>
        <div className="grid grid-cols-1 gap-x-8 gap-y-1 text-sm sm:grid-cols-2">
          <p>
            <span className="text-muted-foreground">Empresa:</span> {data.tenant_name}
          </p>
          <p>
            <span className="text-muted-foreground">Empleat:</span> {data.employee_name}
          </p>
          <p>
            <span className="text-muted-foreground">Període:</span> {formatDate(data.period_from)} –{" "}
            {formatDate(data.period_to)}
          </p>
          <p>
            <span className="text-muted-foreground">L&apos;enllaç caduca:</span>{" "}
            {formatDateTime(data.expires_at)}
          </p>
        </div>
        <div className="flex flex-wrap gap-2 pt-1">
          <button
            type="button"
            onClick={handleDownloadJson}
            className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted"
          >
            <Download className="h-4 w-4" /> JSON
          </button>
          <button
            type="button"
            onClick={handleDownloadPunchesCsv}
            className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted"
          >
            <Download className="h-4 w-4" /> CSV fitxatges
          </button>
          {showConsolidated ? (
            <button
              type="button"
              onClick={handleDownloadSummariesCsv}
              className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted"
            >
              <Download className="h-4 w-4" /> CSV consolidat
            </button>
          ) : null}
        </div>
      </header>

      <div className="flex flex-wrap gap-1 border-b">
        <button
          type="button"
          onClick={() => setMainTab("punches")}
          className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
            mainTab === "punches"
              ? "border-foreground text-foreground"
              : "border-transparent text-muted-foreground hover:text-foreground"
          }`}
        >
          Fitxatges reals
          <span className="ml-1.5 text-xs font-normal text-muted-foreground">
            ({data.punches.length}/{data.punches_total})
          </span>
        </button>
        {showConsolidated ? (
          <button
            type="button"
            onClick={() => setMainTab("consolidated")}
            className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
              mainTab === "consolidated"
                ? "border-foreground text-foreground"
                : "border-transparent text-muted-foreground hover:text-foreground"
            }`}
          >
            Registre consolidat
            <span className="ml-1.5 text-xs font-normal text-muted-foreground">
              ({data.summaries.length}/{data.summaries_total})
            </span>
          </button>
        ) : null}
      </div>

      {mainTab === "punches" ? (
        <section className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm text-muted-foreground">
              Vista dels fitxatges crus registrats al sistema.
            </p>
            <div className="inline-flex rounded-md border p-0.5">
              <button
                type="button"
                onClick={() => setPunchView("timeline")}
                className={`inline-flex items-center gap-1.5 rounded px-2.5 py-1 text-xs font-medium ${
                  punchView === "timeline" ? "bg-muted text-foreground" : "text-muted-foreground"
                }`}
              >
                <CalendarDays className="h-3.5 w-3.5" />
                Per dies
              </button>
              <button
                type="button"
                onClick={() => setPunchView("table")}
                className={`inline-flex items-center gap-1.5 rounded px-2.5 py-1 text-xs font-medium ${
                  punchView === "table" ? "bg-muted text-foreground" : "text-muted-foreground"
                }`}
              >
                <LayoutList className="h-3.5 w-3.5" />
                Taula
              </button>
            </div>
          </div>

          {punchView === "timeline" ? (
            <PunchTimeline punches={data.punches} />
          ) : (
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead className="bg-muted/50 text-left text-xs uppercase text-muted-foreground">
                  <tr>
                    <th className="px-3 py-2">Tipus</th>
                    <th className="px-3 py-2">Data i hora</th>
                    <th className="px-3 py-2">Origen</th>
                    <th className="px-3 py-2">Ubicació</th>
                    <th className="px-3 py-2">Dispositiu</th>
                    <th className="px-3 py-2">Incidències</th>
                  </tr>
                </thead>
                <tbody>
                  {data.punches.map((p) => (
                    <tr key={p.id} className="border-t">
                      <td className="px-3 py-2 whitespace-nowrap">{punchTypeLabel(p.punch_type)}</td>
                      <td className="px-3 py-2 whitespace-nowrap">{formatDateTime(p.occurred_at)}</td>
                      <td className="px-3 py-2 whitespace-nowrap">{p.source ?? ""}</td>
                      <td className="px-3 py-2">{p.location_name_snapshot ?? ""}</td>
                      <td className="px-3 py-2">{p.device_name_snapshot ?? ""}</td>
                      <td className="px-3 py-2">{(p.anomaly_codes ?? []).join(", ")}</td>
                    </tr>
                  ))}
                  {data.punches.length === 0 ? (
                    <tr>
                      <td colSpan={6} className="px-3 py-6 text-center text-muted-foreground">
                        Cap fitxatge en aquest període.
                      </td>
                    </tr>
                  ) : null}
                </tbody>
              </table>
            </div>
          )}

          {punchesRemaining > 0 ? (
            <button
              type="button"
              onClick={() => void handleLoadMorePunches()}
              disabled={loadingMorePunches}
              className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted disabled:opacity-50"
            >
              {loadingMorePunches ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              Carregar-ne més ({punchesRemaining})
            </button>
          ) : null}
        </section>
      ) : null}

      {mainTab === "consolidated" && showConsolidated ? (
        <section className="space-y-2">
          <div className="overflow-x-auto rounded-lg border">
            <table className="w-full text-sm">
              <thead className="bg-muted/50 text-left text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="px-3 py-2">Dia</th>
                  <th className="px-3 py-2">Tipus</th>
                  <th className="px-3 py-2">Entrada</th>
                  <th className="px-3 py-2">Sortida</th>
                  <th className="px-3 py-2">Previst</th>
                  <th className="px-3 py-2">Treballat</th>
                  <th className="px-3 py-2">Efectiu</th>
                  <th className="px-3 py-2">Extra</th>
                  <th className="px-3 py-2">Estat</th>
                </tr>
              </thead>
              <tbody>
                {data.summaries.map((s) => (
                  <tr key={s.work_date} className="border-t">
                    <td className="px-3 py-2 whitespace-nowrap">{formatDate(s.work_date)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{s.day_type ?? ""}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{formatDateTime(s.starts_at)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{formatDateTime(s.ends_at)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{formatMinutes(s.expected_minutes)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{formatMinutes(s.worked_minutes)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">
                      {formatMinutes(s.effective_work_minutes)}
                    </td>
                    <td className="px-3 py-2 whitespace-nowrap">{formatMinutes(s.overtime_minutes)}</td>
                    <td className="px-3 py-2 whitespace-nowrap">{s.summary_status ?? ""}</td>
                  </tr>
                ))}
                {data.summaries.length === 0 ? (
                  <tr>
                    <td colSpan={9} className="px-3 py-6 text-center text-muted-foreground">
                      Cap dia consolidat en aquest període.
                    </td>
                  </tr>
                ) : null}
              </tbody>
            </table>
          </div>
          {summariesRemaining > 0 ? (
            <button
              type="button"
              onClick={() => void handleLoadMoreSummaries()}
              disabled={loadingMoreSummaries}
              className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted disabled:opacity-50"
            >
              {loadingMoreSummaries ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              Carregar-ne més ({summariesRemaining})
            </button>
          ) : null}
        </section>
      ) : null}

      <footer className="border-t pt-4 text-xs text-muted-foreground">
        Document generat el {formatDateTime(data.generated_at)} · Accés temporal per a la Inspecció de
        Treball.
      </footer>
    </div>
  );
}

export default function InspectPage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto max-w-md px-4 py-16 text-center text-sm text-muted-foreground">…</div>
      }
    >
      <InspectPageInner />
    </Suspense>
  );
}
