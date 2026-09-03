"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  fetchPortalAbsenceTypes,
  fetchPortalAbsences,
  PortalAbsenceRow,
  PortalAbsenceType,
  PortalApiError,
  requestPortalAbsence,
} from "../api/portalApi";

function absenceName(cfg: PortalAbsenceType, lang: string): string {
  return cfg.name_i18n?.[lang] ?? cfg.name_i18n?.es ?? cfg.absence_type;
}

function statusLabel(status: string, t: (key: string, fallback: string) => string): string {
  switch (status) {
    case "requested":
      return t("employee_portal.absences.status_requested", "Pendent");
    case "approved":
      return t("employee_portal.absences.status_approved", "Aprovada");
    case "rejected":
      return t("employee_portal.absences.status_rejected", "Rebutjada");
    case "active":
      return t("employee_portal.absences.status_active", "Activa");
    default:
      return status;
  }
}

export function PortalAbsencesPage() {
  const { t, i18n } = useTranslation("portal");
  const lang = i18n.language?.slice(0, 2) ?? "ca";

  const [types, setTypes] = useState<PortalAbsenceType[]>([]);
  const [absences, setAbsences] = useState<PortalAbsenceRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [formOpen, setFormOpen] = useState(false);

  const d = new Date();
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

  const [absenceType, setAbsenceType] = useState("");
  const [startDate, setStartDate] = useState(today);
  const [endDate, setEndDate] = useState(today);
  const [notes, setNotes] = useState("");
  const [partialStart, setPartialStart] = useState("");
  const [partialEnd, setPartialEnd] = useState("");

  const selectedCfg = types.find((c) => c.absence_type === absenceType);
  const isPartial = selectedCfg?.is_partial ?? false;

  const load = useCallback(async () => {
    setError(null);
    try {
      const [typeRows, absenceRows] = await Promise.all([
        fetchPortalAbsenceTypes(),
        fetchPortalAbsences(),
      ]);
      setTypes(typeRows);
      setAbsences(absenceRows);
    } catch (err) {
      setError(err instanceof PortalApiError ? err.code : "load_failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!absenceType) return;
    setSubmitting(true);
    setError(null);
    setSuccess(null);
    try {
      const result = await requestPortalAbsence({
        absence_type: absenceType,
        start_date: startDate,
        end_date: endDate,
        notes: notes || undefined,
        partial_start_time: isPartial && partialStart ? partialStart : undefined,
        partial_end_time: isPartial && partialEnd ? partialEnd : undefined,
      });
      setSuccess(
        result.status === "approved"
          ? t("employee_portal.absences.request_approved", "Sol·licitud registrada i aprovada")
          : t("employee_portal.absences.request_sent", "Sol·licitud enviada al gestor"),
      );
      setFormOpen(false);
      setNotes("");
      await load();
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "request_failed";
      if (code === "absence_overlap") {
        setError(t("employee_portal.absences.overlap", "Ja hi ha una absència en aquestes dates"));
      } else {
        setError(code);
      }
    } finally {
      setSubmitting(false);
    }
  }

  if (loading) {
    return (
      <p className="text-muted-foreground py-16 text-center text-sm">
        {t("employee_portal.loading", "Carregant…")}
      </p>
    );
  }

  return (
    <div className="flex w-full flex-col gap-6">
      <div className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-xl font-semibold">
            {t("employee_portal.absences.title", "Absències")}
          </h1>
          <p className="text-muted-foreground text-sm">
            {t("employee_portal.absences.subtitle", "Sol·licita permisos i consulta l'estat")}
          </p>
        </div>
        <button
          type="button"
          onClick={() => setFormOpen((v) => !v)}
          className="rounded-md bg-primary px-3 py-2 text-sm font-medium text-primary-foreground"
        >
          {formOpen
            ? t("employee_portal.absences.cancel_form", "Cancel·lar")
            : t("employee_portal.absences.new_request", "Nova sol·licitud")}
        </button>
      </div>

      {formOpen && (
        <form onSubmit={(e) => void handleSubmit(e)} className="space-y-4 rounded-lg border p-4">
          <div>
            <label className="mb-1 block text-sm font-medium">
              {t("employee_portal.absences.form_type", "Tipus")}
            </label>
            <select
              value={absenceType}
              onChange={(e) => setAbsenceType(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              required
            >
              <option value="">
                {t("employee_portal.absences.form_type_placeholder", "Selecciona…")}
              </option>
              {types.map((cfg) => (
                <option key={cfg.id} value={cfg.absence_type}>
                  {absenceName(cfg, lang)}
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="mb-1 block text-sm font-medium">
                {t("employee_portal.absences.form_start", "Inici")}
              </label>
              <input
                type="date"
                value={startDate}
                onChange={(e) => {
                  setStartDate(e.target.value);
                  if (e.target.value > endDate) setEndDate(e.target.value);
                }}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                required
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium">
                {t("employee_portal.absences.form_end", "Fi")}
              </label>
              <input
                type="date"
                value={endDate}
                min={startDate}
                onChange={(e) => setEndDate(e.target.value)}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                required
              />
            </div>
          </div>

          {isPartial && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="mb-1 block text-sm font-medium">
                  {t("employee_portal.absences.form_partial_start", "Hora inici")}
                </label>
                <input
                  type="time"
                  value={partialStart}
                  onChange={(e) => setPartialStart(e.target.value)}
                  className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                />
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium">
                  {t("employee_portal.absences.form_partial_end", "Hora fi")}
                </label>
                <input
                  type="time"
                  value={partialEnd}
                  onChange={(e) => setPartialEnd(e.target.value)}
                  className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                />
              </div>
            </div>
          )}

          <div>
            <label className="mb-1 block text-sm font-medium">
              {t("employee_portal.absences.form_notes", "Notes (opcional)")}
            </label>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
            />
          </div>

          <button
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-primary py-2 text-sm font-medium text-primary-foreground disabled:opacity-60"
          >
            {submitting
              ? t("employee_portal.absences.submitting", "Enviant…")
              : t("employee_portal.absences.submit", "Enviar sol·licitud")}
          </button>
        </form>
      )}

      {success && (
        <p className="rounded-md border border-emerald-500/40 bg-emerald-50 px-3 py-2 text-sm text-emerald-800">
          {success}
        </p>
      )}
      {error && (
        <p className="text-destructive text-sm" role="alert">
          {error}
        </p>
      )}

      <div className="space-y-2">
        <h2 className="text-muted-foreground text-sm font-semibold uppercase tracking-wide">
          {t("employee_portal.absences.list_title", "Les meves sol·licituds")}
        </h2>
        {absences.length === 0 ? (
          <p className="text-muted-foreground py-4 text-center text-sm">
            {t("employee_portal.absences.empty", "Cap absència registrada")}
          </p>
        ) : (
          <ul className="divide-y rounded-lg border">
            {absences.map((row) => (
              <li key={row.id} className="px-4 py-3 text-sm">
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="font-medium">
                      {types.find((t) => t.absence_type === row.absence_type)
                        ? absenceName(
                            types.find((t) => t.absence_type === row.absence_type)!,
                            lang,
                          )
                        : row.absence_type}
                    </p>
                    <p className="text-muted-foreground text-xs">
                      {row.start_date}
                      {row.end_date !== row.start_date ? ` → ${row.end_date}` : ""}
                      {row.partial_start_time && row.partial_end_time
                        ? ` · ${row.partial_start_time.slice(0, 5)}–${row.partial_end_time.slice(0, 5)}`
                        : ""}
                    </p>
                  </div>
                  <span className="rounded-full bg-muted px-2 py-0.5 text-xs">
                    {statusLabel(row.status, t)}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
