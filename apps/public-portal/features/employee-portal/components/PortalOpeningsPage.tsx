"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { Loader2, MapPin, Moon } from "lucide-react";
import {
  claimPortalShiftOpening,
  fetchPortalShiftOpenings,
  PortalApiError,
  type PortalShiftOpening,
  withdrawPortalShiftOpeningClaim,
} from "../api/portalApi";
import { addDaysIso } from "../utils/scheduleUtils";
import { getPortalTodayIso } from "../utils/portalDateUtils";

function timeLabel(o: PortalShiftOpening, overnightSuffix: string): string {
  const base = `${o.start_time}–${o.end_time}`;
  return o.spans_midnight ? `${base}${overnightSuffix}` : base;
}

export function PortalOpeningsPage() {
  const { t } = useTranslation("portal");
  const router = useRouter();
  const todayIso = getPortalTodayIso();
  const from = todayIso;
  const to = useMemo(() => addDaysIso(todayIso, 28), [todayIso]);

  const [openings, setOpenings] = useState<PortalShiftOpening[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const overnightSuffix = t("employee_portal.schedule.overnight_suffix", " (+1)");

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalShiftOpenings(from, to);
      setOpenings(data.openings ?? []);
    } catch (err) {
      if (err instanceof PortalApiError && err.code === "missing_session") {
        router.replace("/portal/expired");
        return;
      }
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.openings.error_load_failed", "No s'han pogut carregar les vacants"),
      );
    } finally {
      setLoading(false);
    }
  }, [from, to, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  async function onClaim(opening: PortalShiftOpening) {
    setBusyId(opening.id);
    setError(null);
    try {
      await claimPortalShiftOpening({ opening_id: opening.id });
      await load();
    } catch (err) {
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.openings.error_claim", "No s'ha pogut reclamar la vacant"),
      );
    } finally {
      setBusyId(null);
    }
  }

  async function onWithdraw(opening: PortalShiftOpening) {
    const claimId = opening.my_claim?.id;
    if (!claimId) return;
    setBusyId(opening.id);
    setError(null);
    try {
      await withdrawPortalShiftOpeningClaim({ claim_id: claimId });
      await load();
    } catch (err) {
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.openings.error_withdraw", "No s'ha pogut retirar la candidatura"),
      );
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="mx-auto flex w-full max-w-lg flex-col gap-4 px-4 py-6">
      <header className="space-y-1">
        <h1 className="text-xl font-semibold text-foreground">
          {t("employee_portal.openings.title", "Vacants")}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t(
            "employee_portal.openings.subtitle",
            "Torns oberts al teu centre. Pots reclamar-los si ets elegible.",
          )}
        </p>
      </header>

      {loading ? (
        <div className="flex items-center justify-center gap-2 py-12 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.openings.loading", "Carregant vacants…")}
        </div>
      ) : error ? (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      ) : openings.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
          {t("employee_portal.openings.empty", "No hi ha vacants obertes aquestes setmanes")}
        </div>
      ) : (
        <ul className="flex flex-col gap-3">
          {openings.map((o) => {
            const pending = o.my_claim?.status === "pending";
            const accepted = o.my_claim?.status === "accepted";
            const canClaim = o.eligible && !o.my_claim;
            const busy = busyId === o.id;

            return (
              <li key={o.id} className="rounded-lg border border-border p-3 space-y-2">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-foreground">
                      {o.title?.trim() || t("employee_portal.openings.untitled", "Torn vacant")}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {o.opening_date} · {timeLabel(o, overnightSuffix)}
                      {o.spans_midnight ? <Moon className="ml-1 inline h-3 w-3" /> : null}
                    </p>
                    {o.role_name ? (
                      <p className="mt-1 text-xs text-muted-foreground">{o.role_name}</p>
                    ) : null}
                    {o.location_name ? (
                      <p className="mt-0.5 flex items-center gap-1 text-xs text-muted-foreground">
                        <MapPin className="h-3 w-3 shrink-0" />
                        <span className="truncate">{o.location_name}</span>
                      </p>
                    ) : null}
                  </div>
                  <span className="shrink-0 rounded-md bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
                    {o.places_remaining}/{o.places_total}
                  </span>
                </div>

                <p className="text-[11px] text-muted-foreground">
                  {o.claim_policy === "first_eligible"
                    ? t("employee_portal.openings.policy_first", "Assignació immediata si ets elegible")
                    : t("employee_portal.openings.policy_approval", "Requereix aprovació del responsable")}
                </p>

                {!o.eligible && !o.my_claim ? (
                  <p className="text-xs text-amber-700 dark:text-amber-400">
                    {t("employee_portal.openings.not_eligible", "No elegible")}
                    {o.eligibility.blocks?.length
                      ? `: ${o.eligibility.blocks.join(", ")}`
                      : ""}
                  </p>
                ) : null}

                {accepted ? (
                  <p className="text-xs font-medium text-emerald-700">
                    {t("employee_portal.openings.accepted", "Assignat")}
                  </p>
                ) : pending ? (
                  <div className="flex items-center gap-2">
                    <p className="text-xs text-muted-foreground">
                      {t("employee_portal.openings.pending", "Candidatura pendent")}
                    </p>
                    <button
                      type="button"
                      disabled={busy}
                      className="rounded-md border border-border px-2.5 py-1 text-xs hover:bg-muted disabled:opacity-50"
                      onClick={() => void onWithdraw(o)}
                    >
                      {busy ? <Loader2 className="h-3 w-3 animate-spin" /> : t("employee_portal.openings.withdraw", "Retirar")}
                    </button>
                  </div>
                ) : canClaim ? (
                  <button
                    type="button"
                    disabled={busy}
                    className="rounded-md bg-foreground px-3 py-1.5 text-xs font-medium text-background disabled:opacity-50"
                    onClick={() => void onClaim(o)}
                  >
                    {busy ? (
                      <Loader2 className="inline h-3 w-3 animate-spin" />
                    ) : (
                      t("employee_portal.openings.claim", "Reclamar")
                    )}
                  </button>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
