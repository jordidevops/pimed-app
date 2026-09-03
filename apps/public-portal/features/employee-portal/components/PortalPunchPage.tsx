"use client";



import { useCallback, useEffect, useMemo, useState } from "react";

import { useRouter } from "next/navigation";
import Link from "next/link";

import { useTranslation } from "react-i18next";

import {

  fetchPortalMe,

  fetchPortalPauseConfigs,

  fetchPortalSchedule,

  fetchPortalToday,

  generateClientOpId,

  PortalApiError,

  recordPortalPunch,

  refreshPortalSession,

  type PortalEmployee,

  type PortalPauseConfig,

  type PortalPunch,

  type PortalScheduleDay,

} from "../api/portalApi";

import { savePortalPunchOpLocally, getPortalAllDisplayOps } from "../db/portalOutbox";

import {

  isPortalNetworkFailure,

  usePortalAttendanceSync,

} from "../hooks/usePortalAttendanceSync";

import { mergePendingPortalPunches } from "../utils/mergePendingPunches";

import { derivePortalPunchStatus, computePunchDayState, isLegacyInOutOnly, isMobileWorkProfile, type PortalPunchDayState, type PortalPunchStatus, type PortalPunchType } from "../utils/punchStatus";
import { buildDeviceInfo } from "../utils/deviceInfo";

import { readPortalPinRequired, readPortalEmployeeSnapshot } from "@/lib/employee-portal/sessionFlags";

import { PortalDailyTimeline } from "./PortalDailyTimeline";

import { PinGate } from "./PinGate";

import { PortalOfflineStatus } from "./PortalOfflineStatus";

import { PortalPunchActionPanel } from "./PortalPunchActionPanel";
import { PortalWorkScheduleStatusCard } from "./PortalWorkScheduleStatusCard";
import { PortalPushOptIn } from "./PortalPushOptIn";
import { PortalPauseButtonGroup } from "./PortalPauseButtonGroup";
import { PortalPauseActiveButton } from "./PortalPauseActiveButton";
import { PORTAL_PUNCH_HERO_CLASS } from "../utils/portalPauseIcons";

function localIsoDate(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}



export function PortalPunchPage() {

  const { t } = useTranslation("portal");

  const router = useRouter();

  const [employee, setEmployee] = useState<PortalEmployee | null>(null);

  const [punches, setPunches] = useState<PortalPunch[]>([]);
  const [pauseConfigs, setPauseConfigs] = useState<PortalPauseConfig[]>([]);
  const [todaySchedule, setTodaySchedule] = useState<PortalScheduleDay | null>(null);
  const [activePauseType, setActivePauseType] = useState<string | null>(null);
  const [workProfile, setWorkProfile] = useState<string>("fixed_site");
  const [legacyInOutOnly, setLegacyInOutOnly] = useState(true);
  const [dayState, setDayState] = useState<PortalPunchDayState>("off");
  const [punchOnlyAtStations, setPunchOnlyAtStations] = useState(false);
  const [profileReady, setProfileReady] = useState(false);

  const applyPunchProfile = useCallback(
    (source: { work_profile?: string | null; legacy_in_out_only?: boolean | null }) => {
      const profile = source.work_profile ?? "fixed_site";
      setWorkProfile(profile);
      setLegacyInOutOnly(source.legacy_in_out_only ?? isLegacyInOutOnly(profile));
      setProfileReady(true);
    },
    [],
  );

  const [localOps, setLocalOps] = useState<Awaited<ReturnType<typeof getPortalAllDisplayOps>>>([]);

  const [loading, setLoading] = useState(true);

  const [punching, setPunching] = useState(false);
  const [punchingType, setPunchingType] = useState<PortalPunchType | null>(null);

  const [error, setError] = useState<string | null>(null);

  const [toast, setToast] = useState<string | null>(null);

  const [needsRePin, setNeedsRePin] = useState(false);

  const [rePinError, setRePinError] = useState<string | null>(null);



  const reloadLocalOps = useCallback(async (tenantId: string, employeeId: string) => {

    const ops = await getPortalAllDisplayOps(tenantId, employeeId);

    setLocalOps(ops);

    return ops;

  }, []);



  const load = useCallback(async () => {

    setError(null);



    if (!navigator.onLine) {
      const snapshot = readPortalEmployeeSnapshot();
      if (snapshot) {
        setEmployee(snapshot);
        applyPunchProfile(snapshot);
        await reloadLocalOps(snapshot.tenant_id, snapshot.id);
      }
      setLoading(false);
      return;
    }



    try {

      const [me, today, configs] = await Promise.all([
        fetchPortalMe(),
        fetchPortalToday(),
        fetchPortalPauseConfigs(),
      ]);

      const todayIso = localIsoDate();
      let scheduleDay: PortalScheduleDay | null = null;
      try {
        const schedule = await fetchPortalSchedule(todayIso, todayIso);
        scheduleDay = schedule.days[0] ?? null;
      } catch {
        scheduleDay = null;
      }
      setTodaySchedule(scheduleDay);

      setEmployee(me);

      setPunches(today.punches ?? []);
      setActivePauseType(today.active_pause_type ?? null);
      applyPunchProfile({
        work_profile: today.work_profile ?? me.work_profile,
        legacy_in_out_only: today.legacy_in_out_only ?? me.legacy_in_out_only,
      });
      setDayState((today.day_state as PortalPunchDayState) ?? computePunchDayState(today.punches ?? []));
      setPunchOnlyAtStations(Boolean(today.punch_only_at_stations));
      setPauseConfigs(configs);

      await reloadLocalOps(me.tenant_id, me.id);

    } catch (err) {

      if (err instanceof PortalApiError) {

        if (

          err.code === "session_expired" ||

          err.code === "pin_required" ||

          (err.code === "missing_session" && readPortalPinRequired())

        ) {

          setNeedsRePin(true);

          setLoading(false);

          return;

        }

        if (["missing_session", "session_expired", "token_revoked"].includes(err.code)) {

          router.replace("/portal/expired");

          return;

        }

      }

      setError(err instanceof PortalApiError ? err.code : "load_failed");

    } finally {

      setLoading(false);

    }

  }, [reloadLocalOps, router, applyPunchProfile]);



  const sync = usePortalAttendanceSync(employee?.id ?? "", employee?.tenant_id ?? "", {
    onPunchSynced: ({ punch_type }) => {
      setToast(
        punch_type === "in"
          ? t("employee_portal.punch_in_ok", "Entrada registrada")
          : t("employee_portal.punch_out_ok", "Sortida registrada"),
      );
      void load();
    },
    onNeedsRePin: () => setNeedsRePin(true),
  });



  useEffect(() => {
    if (needsRePin) return;
    void load();
    const id = window.setInterval(() => void load(), 60_000);
    return () => window.clearInterval(id);
  }, [load, needsRePin]);

  // Si la cua s'ha buidat però queda l'avís offline, netejar-lo
  useEffect(() => {
    if (sync.pendingCount > 0 || sync.isSyncing || !sync.isOnline) return;
    setToast((current) => {
      if (!current) return current;
      const offlineMessages = [
        t("employee_portal.punch_in_offline", "Entrada desada — es sincronitzarà en tornar online"),
        t("employee_portal.punch_out_offline", "Sortida desada — es sincronitzarà en tornar online"),
      ];
      return offlineMessages.includes(current) ? null : current;
    });
  }, [sync.pendingCount, sync.isSyncing, sync.isOnline, t]);



  const displayPunches = useMemo(

    () => mergePendingPortalPunches(punches, localOps),

    [punches, localOps],

  );



  const lastPunch = displayPunches.length > 0 ? displayPunches[displayPunches.length - 1]! : null;
  const resolvedDayState = displayPunches.length > 0 ? computePunchDayState(displayPunches) : dayState;
  const status = useMemo(
    () =>
      derivePortalPunchStatus(lastPunch, {
        workProfile,
        legacyInOutOnly,
        punches: displayPunches,
        dayState: resolvedDayState,
      }),
    [lastPunch, workProfile, legacyInOutOnly, displayPunches, resolvedDayState],
  );
  const isMobileProfile = isMobileWorkProfile(workProfile) && !legacyInOutOnly;

  function punchToastMessage(punchType: PortalPunchType, offline: boolean): string {
    if (offline) {
      switch (punchType) {
        case "in":
          return t("employee_portal.punch_in_offline", "Entrada desada — es sincronitzarà en tornar online");
        case "out":
          return t("employee_portal.punch_out_offline", "Sortida desada — es sincronitzarà en tornar online");
        case "day_start":
          return t("employee_portal.punch_day_start_offline", "Inici jornada desat — es sincronitzarà en tornar online");
        case "day_end":
          return t("employee_portal.punch_day_end_offline", "Fi jornada desat — es sincronitzarà en tornar online");
        case "travel_start":
          return t("employee_portal.punch_travel_start_offline", "Desplaçament desat — es sincronitzarà en tornar online");
        case "travel_end":
          return t("employee_portal.punch_travel_end_offline", "Arribada desada — es sincronitzarà en tornar online");
        case "break_start":
          return t("employee_portal.pause_start_offline", "Pausa desada — es sincronitzarà en tornar online");
        default:
          return t("employee_portal.pause_end_offline", "Fi de pausa desada — es sincronitzarà en tornar online");
      }
    }
    switch (punchType) {
      case "in":
        return t("employee_portal.punch_in_ok", "Entrada registrada");
      case "out":
        return t("employee_portal.punch_out_ok", "Sortida registrada");
      case "day_start":
        return t("employee_portal.punch_day_start_ok", "Inici de jornada registrat");
      case "day_end":
        return t("employee_portal.punch_day_end_ok", "Fi de jornada registrat");
      case "travel_start":
        return t("employee_portal.punch_travel_start_ok", "Desplaçament iniciat");
      case "travel_end":
        return t("employee_portal.punch_travel_end_ok", "Desplaçament finalitzat");
      case "break_start":
        return t("employee_portal.pause_start_ok", "Pausa iniciada");
      default:
        return t("employee_portal.pause_end_ok", "Pausa tancada");
    }
  }

  async function queueOfflinePunch(
    punchType: PortalPunchType,
    tenantId: string,
    employeeId: string,
    device_info: Record<string, string>,
    client_op_id: string,
    occurred_at: string,
    pause_type?: string,
    pause_counts_as_work?: boolean,
  ): Promise<void> {
    await savePortalPunchOpLocally({
      client_op_id,
      punch_type: punchType,
      employee_id: employeeId,
      tenant_id: tenantId,
      occurred_at,
      device_info,
      pause_type: pause_type ?? null,
      pause_counts_as_work: pause_counts_as_work ?? null,
    });

    await sync.refreshCounts();

    await reloadLocalOps(tenantId, employeeId);

    setToast(punchToastMessage(punchType, true));
  }

  async function handlePunchAction(
    punchType: PortalPunchType,
    pause_type?: string,
    pause_counts_as_work?: boolean,
  ) {

    if (!employee) return;

    if (punchOnlyAtStations) {
      setError(
        t(
          "employee_portal.punch_only_at_stations",
          "La teva empresa només permet fitxar des de l'estació. Escaneja el QR a la tablet del centre de treball.",
        ),
      );
      return;
    }

    setPunching(true);
    setPunchingType(punchType);

    setToast(null);

    setError(null);



    const client_op_id = generateClientOpId();

    const occurred_at = new Date().toISOString();

    const device_info = buildDeviceInfo("employee_portal");



    if (!navigator.onLine) {

      try {

        await queueOfflinePunch(
          punchType,
          employee.tenant_id,
          employee.id,
          device_info,
          client_op_id,
          occurred_at,
          pause_type,
          pause_counts_as_work,
        );

      } catch {

        setError(t("employee_portal.offline_save_failed", "No s'ha pogut desar el fitxatge localment"));

      } finally {

        setPunching(false);
        setPunchingType(null);

      }

      return;

    }



    try {

      const result = await recordPortalPunch({
        client_op_id,
        punch_type: punchType,
        occurred_at,
        device_info,
        pause_type,
        pause_counts_as_work,
      });



      if (result.status === "duplicate") {

        setToast(t("employee_portal.punch_duplicate", "Ja s'havia registrat aquest fitxatge"));

      } else {

        setToast(punchToastMessage(punchType, false));

      }



      await load();

    } catch (err) {

      if (isPortalNetworkFailure(err)) {

        try {

          await savePortalPunchOpLocally({
            client_op_id,
            punch_type: punchType,
            employee_id: employee.id,
            tenant_id: employee.tenant_id,
            occurred_at,
            device_info,
            pause_type: pause_type ?? null,
            pause_counts_as_work: pause_counts_as_work ?? null,
          });

          await sync.refreshCounts();

          await reloadLocalOps(employee.tenant_id, employee.id);

          setToast(punchToastMessage(punchType, true));

          return;

        } catch {

          setError(t("employee_portal.offline_save_failed", "No s'ha pogut desar el fitxatge localment"));

          return;

        }

      }



      const code = err instanceof PortalApiError ? err.code : "punch_failed";

      if (code === "invalid_sequence") {
        setError(
          isMobileProfile && resolvedDayState === "off"
            ? t(
                "employee_portal.punch_sequence_day_start",
                "Cal registrar l'inici de jornada abans d'entrar a un client",
              )
            : t("employee_portal.punch_sequence_error", "Seqüència de fitxatge no vàlida"),
        );
      } else if (code === "protocol_pending") {
        setError(
          t(
            "employee_portal.protocol_pending_punch",
            "Has de llegir i confirmar el protocol de registre horari abans de fitxar.",
          ),
        );
      } else if (code === "punch_only_at_stations") {
        setError(
          t(
            "employee_portal.punch_only_at_stations",
            "La teva empresa només permet fitxar des de l'estació. Escaneja el QR a la tablet del centre de treball.",
          ),
        );
      } else if (["missing_session", "session_expired", "pin_required"].includes(code)) {

        setNeedsRePin(true);

      } else if (code === "token_revoked") {

        router.replace("/portal/expired");

      } else {

        setError(code);

      }

    } finally {

      setPunching(false);
      setPunchingType(null);

    }

  }



  async function handleRePin(pin: string) {

    setRePinError(null);

    try {

      await refreshPortalSession(pin);

      setNeedsRePin(false);

      await load();

      await sync.drain();

    } catch (err) {

      const code = err instanceof PortalApiError ? err.code : "pin_invalid";

      if (code === "token_revoked") {

        router.replace("/portal/expired");

        return;

      }

      setRePinError(code);

    }

  }



  if (needsRePin) {

    return (

      <div className="space-y-4">

        <p className="text-muted-foreground text-center text-sm">

          {t("employee_portal.repin_hint", "La sessió ha caducat. Introdueix el PIN per sincronitzar.")}

        </p>

        <PinGate onSubmit={handleRePin} errorCode={rePinError} />

      </div>

    );

  }



  if (loading || !profileReady) {

    return (

      <p className="text-muted-foreground py-16 text-center text-sm">

        {t("employee_portal.loading", "Carregant…")}

      </p>

    );

  }



  return (

    <div className="flex w-full flex-col gap-8">

      <PortalOfflineStatus

        isOnline={sync.isOnline}

        pendingCount={sync.pendingCount}

        quarantinedCount={sync.quarantinedCount}

        isSyncing={sync.isSyncing}

      />



      <div className="text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.nav_punch", "Fitxatge")}
        </h1>
        <p className="text-muted-foreground mt-1 text-sm">
          {punchOnlyAtStations
            ? t(
                "employee_portal.punch.subtitle_station_only",
                "Consulta el teu horari i mostra el QR a l'estació per fitxar.",
              )
            : t(
                "employee_portal.punch.subtitle",
                "Registra la teva entrada, sortida i pauses.",
              )}
        </p>
        <p className="mt-3 text-sm">
          <Link href="/portal/documents" className="text-primary font-medium underline-offset-2 hover:underline">
            {t("employee_portal.documents.hours_link", "Com es calculen les meves hores?")}
          </Link>
        </p>
      </div>

      <PortalWorkScheduleStatusCard
        schedule={todaySchedule}
        punches={displayPunches}
        presenceStatus={status}
      />

      {punchOnlyAtStations ? (
        <div className="space-y-3">
          <div className="rounded-xl border border-amber-500/40 bg-amber-50 px-4 py-3 text-sm text-amber-950 dark:bg-amber-950/30 dark:text-amber-100">
            {t(
              "employee_portal.punch.station_only_banner",
              "El fitxatge des del mòbil està desactivat. Apropa el QR a la tablet de l'estació per registrar entrada o sortida.",
            )}
          </div>
          <Link
            href="/portal/station-qr"
            className="flex w-full items-center justify-center rounded-2xl bg-primary px-4 py-4 text-base font-semibold text-primary-foreground shadow-sm transition hover:opacity-95"
          >
            {t("employee_portal.punch.open_station_qr", "Obrir QR d'estació")}
          </Link>
        </div>
      ) : null}

      <PortalPushOptIn context="punch" />

      {!punchOnlyAtStations ? (
      <div className="flex w-full flex-col items-center">
        {status === "on_pause" ? (
          <div className={`flex shrink-0 ${PORTAL_PUNCH_HERO_CLASS} items-center justify-center`}>
            <PortalPauseActiveButton
              activePauseType={activePauseType ?? ""}
              configs={pauseConfigs}
              loading={punching}
              onEndPause={() => void handlePunchAction("break_end", activePauseType ?? undefined)}
            />
          </div>
        ) : (
          <PortalPunchActionPanel
            status={status}
            dayState={resolvedDayState}
            isMobileProfile={isMobileProfile}
            legacyInOutOnly={legacyInOutOnly}
            loadingType={punchingType}
            onPunch={(type) => void handlePunchAction(type)}
          />
        )}
      </div>
      ) : null}

      {!punchOnlyAtStations && (status === "working" || status === "on_pause" || status === "traveling") && pauseConfigs.length > 0 && (
        <div className="min-h-[7.5rem]">
          {status === "working" && (
            <PortalPauseButtonGroup
              configs={pauseConfigs}
              loading={punching}
              onStartPause={(config) =>
                void handlePunchAction("break_start", config.key, config.counts_as_work)
              }
            />
          )}
        </div>
      )}



      {toast && (

        <p className="rounded-md border border-emerald-500/40 bg-emerald-50 px-3 py-2 text-center text-sm text-emerald-800 dark:bg-emerald-950/30 dark:text-emerald-200">

          {toast}

        </p>

      )}



      {error && (

        <p className="text-destructive text-center text-sm" role="alert">

          {error}

        </p>

      )}



      <PortalDailyTimeline punches={displayPunches} />

    </div>

  );

}

