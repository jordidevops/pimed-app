"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { Loader2 } from "lucide-react";
import {
  fetchPortalMyShifts,
  fetchPortalShiftSwaps,
  PortalApiError,
  requestPortalShiftSwap,
  type PortalMyShiftSlot,
  type PortalSwapRequest,
} from "../api/portalApi";
import { addDaysIso } from "../utils/scheduleUtils";
import { getPortalTodayIso } from "../utils/portalDateUtils";

export function PortalSwapsPage() {
  const { t } = useTranslation("portal");
  const router = useRouter();
  const today = getPortalTodayIso();
  const to = addDaysIso(today, 21);

  const [slots, setSlots] = useState<PortalMyShiftSlot[]>([]);
  const [requests, setRequests] = useState<PortalSwapRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [shifts, swaps] = await Promise.all([
        fetchPortalMyShifts(today, to),
        fetchPortalShiftSwaps(),
      ]);
      setSlots(shifts.slots ?? []);
      setRequests(swaps.requests ?? []);
    } catch (err) {
      if (err instanceof PortalApiError && err.code === "missing_session") {
        router.replace("/portal/expired");
        return;
      }
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.swaps.error_load", "No s'han pogut carregar els intercanvis"),
      );
    } finally {
      setLoading(false);
    }
  }, [today, to, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  async function act(slotId: string, kind: "give_away" | "call_off") {
    setBusyId(slotId);
    setError(null);
    try {
      await requestPortalShiftSwap({ requester_slot_id: slotId, kind });
      await load();
    } catch (err) {
      setError(
        err instanceof PortalApiError
          ? err.message
          : t("employee_portal.swaps.error_request", "No s'ha pogut enviar la sol·licitud"),
      );
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="mx-auto flex w-full max-w-lg flex-col gap-4 px-4 py-6">
      <header className="space-y-1">
        <h1 className="text-xl font-semibold text-foreground">
          {t("employee_portal.swaps.title", "Intercanvis")}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t(
            "employee_portal.swaps.subtitle",
            "Cedeix un torn o comunica que no hi podràs assistir. El responsable ha d'aprovar-ho.",
          )}
        </p>
      </header>

      {loading ? (
        <div className="flex items-center justify-center gap-2 py-12 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.swaps.loading", "Carregant…")}
        </div>
      ) : error ? (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
          {error}
        </div>
      ) : (
        <>
          <section className="space-y-2">
            <h2 className="text-sm font-semibold">
              {t("employee_portal.swaps.my_shifts", "Els meus torns")}
            </h2>
            {slots.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t("employee_portal.swaps.no_shifts", "No tens torns publicats propers")}
              </p>
            ) : (
              <ul className="space-y-2">
                {slots.map((s) => {
                  const pending = requests.some(
                    (r) => r.requester_slot_id === s.id && r.status === "pending",
                  );
                  const busy = busyId === s.id;
                  return (
                    <li key={s.id} className="rounded-lg border border-border p-3 space-y-2">
                      <p className="text-sm font-medium">{s.shift_name}</p>
                      <p className="text-xs text-muted-foreground">
                        {s.slot_date} · {s.start_time}–{s.end_time}
                      </p>
                      {pending ? (
                        <p className="text-xs text-muted-foreground">
                          {t("employee_portal.swaps.pending", "Sol·licitud pendent")}
                        </p>
                      ) : (
                        <div className="flex flex-wrap gap-2">
                          <button
                            type="button"
                            disabled={busy}
                            className="rounded-md border border-border px-2.5 py-1 text-xs hover:bg-muted disabled:opacity-50"
                            onClick={() => void act(s.id, "give_away")}
                          >
                            {t("employee_portal.swaps.give_away", "Cedir")}
                          </button>
                          <button
                            type="button"
                            disabled={busy}
                            className="rounded-md border border-border px-2.5 py-1 text-xs hover:bg-muted disabled:opacity-50"
                            onClick={() => void act(s.id, "call_off")}
                          >
                            {t("employee_portal.swaps.call_off", "No puc anar")}
                          </button>
                        </div>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </section>

          <section className="space-y-2">
            <h2 className="text-sm font-semibold">
              {t("employee_portal.swaps.history", "Les meves sol·licituds")}
            </h2>
            {requests.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t("employee_portal.swaps.no_requests", "Cap sol·licitud encara")}
              </p>
            ) : (
              <ul className="space-y-1.5">
                {requests.map((r) => (
                  <li
                    key={r.id}
                    className="flex items-center justify-between rounded border border-border px-2 py-1.5 text-xs"
                  >
                    <span>
                      {r.kind} · {r.slot_date} {r.start_time}–{r.end_time}
                    </span>
                    <span className="text-muted-foreground">{r.status}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  );
}
