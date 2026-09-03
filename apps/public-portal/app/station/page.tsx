"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { StationPinPad } from "@/components/station/StationPinPad";
import { StationBrandingHeader } from "@/components/station/StationBrandingHeader";
import { StationQrScanner } from "@/components/station/StationQrScanner";
import {
  StationWaitingView,
  type WaitingChannel,
} from "@/components/station/StationWaitingView";
import { StationEmployeeSessionView } from "@/components/station/StationEmployeeSessionView";
import { StationEmployeeHistoryView } from "@/components/station/StationEmployeeHistoryView";
import { StationPrivacyBlank } from "@/components/station/StationPrivacyBlank";
import {
  clearStationCredentials,
  fetchStationBootstrap,
  fetchStationEmployeeLocationHint,
  fetchStationEmployees,
  fetchStationPauseConfigs,
  migrateLegacyStationCredentials,
  postStationHeartbeat,
  postStationPunch,
  readStationMeta,
  registerStation,
  resolveStationEmployeeDocument,
  resolveStationIdentityToken,
  verifyStationEmployeePin,
  verifyStationLocalPin,
  writeStationMeta,
  type StationEntryMode,
  type StationIdentityConfirm,
  type StationListLayout,
  type StationPauseConfig,
} from "@/lib/attendance-station/client";
import { generateClientOpId } from "@/features/employee-portal/api/clientOpId";
import {
  clearStationOutbox,
  isStationNetworkFailure,
  saveStationPunchOpLocally,
  saveStationTemporalAnchor,
} from "@/lib/attendance-station/stationOutbox";
import { useStationSync } from "@/lib/attendance-station/useStationSync";
import { parseStationPinError } from "@/lib/attendance-station/kioskLock";
import { useStationManualLock } from "@/lib/attendance-station/useStationManualLock";
import { useStationSession } from "@/lib/attendance-station/useStationSession";
import {
  formatStationPunchError,
  formatStationGeoError,
  type StationDayState,
  type StationEmployeeRow,
} from "@/lib/attendance-station/punchUi";
import { STATION_HEARTBEAT_INTERVAL_MS } from "@/lib/attendance-station/constants";
import { getStationDeviceGeo } from "@/lib/attendance-station/deviceGeo";

type PinModalAction = "adminMenu" | null;

type BootstrapState = {
  name: string;
  display_title?: string | null;
  display_logo_url?: string | null;
  effective_display_title?: string;
  status: string;
  location_path: string | null;
  ready: boolean;
  device_public_id?: string;
  allowed_methods?: string[];
  geo_antifraud_enabled?: boolean;
  geo_antifraud_radius_m?: number;
  location_has_geo?: boolean;
  entry_mode: StationEntryMode;
  employee_list_layout: StationListLayout;
  document_match: "exact" | "suffix";
  document_suffix_length: number;
  identity_confirm: StationIdentityConfirm;
  qr_identity_confirm: StationIdentityConfirm;
  session_idle_seconds: number;
  session_return_countdown_seconds: number;
  session_allow_history: boolean;
  session_history_max_days: number;
  ux_preset?: string;
  waiting_idle_seconds: number;
  mask_names_on_waiting: boolean;
  offline_deferred_punch_enabled?: boolean;
  ops_lockdown?: boolean;
  config_version?: number;
};

function defaultChannel(
  entryMode: StationEntryMode,
  allowManual: boolean,
  allowQr: boolean,
): WaitingChannel {
  if (entryMode === "document_entry" && allowManual) return "document";
  if (allowManual) return "manual";
  if (allowQr) return "qr";
  return "manual";
}

export default function StationPage() {
  const [configured, setConfigured] = useState(false);
  const [loading, setLoading] = useState(true);
  const [pairingCode, setPairingCode] = useState("");
  const [showPairingQrScan, setShowPairingQrScan] = useState(false);
  const [localPin, setLocalPin] = useState("");
  const [stationName, setStationName] = useState("");
  const [bootstrap, setBootstrap] = useState<BootstrapState | null>(null);
  const [channel, setChannel] = useState<WaitingChannel>("manual");
  const [employees, setEmployees] = useState<StationEmployeeRow[]>([]);
  const [pauseConfigs, setPauseConfigs] = useState<StationPauseConfig[]>([]);
  const [assignmentMode, setAssignmentMode] = useState<"zone" | "site_fallback" | null>(null);
  const [search, setSearch] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [documentError, setDocumentError] = useState<string | null>(null);
  const [ambiguousMatches, setAmbiguousMatches] = useState<StationEmployeeRow[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [pinModalAction, setPinModalAction] = useState<PinModalAction>(null);
  const [pinModalError, setPinModalError] = useState<"invalid" | "locked" | null>(null);
  const [pinModalRetryAfter, setPinModalRetryAfter] = useState<number | null>(null);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [privacyBlank, setPrivacyBlank] = useState(false);
  const [waitingIdleNonce, setWaitingIdleNonce] = useState(0);

  const manualLock = useStationManualLock();

  const sessionTimers = useMemo(
    () => ({
      idleSeconds: bootstrap?.session_idle_seconds ?? 60,
      countdownSeconds: bootstrap?.session_return_countdown_seconds ?? 15,
      identityConfirm: bootstrap?.identity_confirm ?? "none",
      qrIdentityConfirm: bootstrap?.qr_identity_confirm ?? "none",
    }),
    [
      bootstrap?.session_idle_seconds,
      bootstrap?.session_return_countdown_seconds,
      bootstrap?.identity_confirm,
      bootstrap?.qr_identity_confirm,
    ],
  );

  const session = useStationSession(sessionTimers);
  const {
    phase,
    employee: sessionEmployee,
    pending,
    flashMessage,
    countdownRemaining,
    selectEmployee,
    confirmIdentity,
    confirmPinSuccess,
    fallbackPinToTapName,
    cancelConfirm,
    endSession,
    notePunchSuccess,
    touchActivity,
    openHistory,
    confirmHistoryPin,
    closeHistory,
    historyPin,
    syncEmployeeFromList,
    patchSessionEmployee,
  } = session;

  const stationDeviceId = configured ? (readStationMeta()?.device_id ?? null) : null;
  const stationSync = useStationSync(stationDeviceId);

  const [employeePinError, setEmployeePinError] = useState<"invalid" | "locked" | null>(null);
  const [employeePinRetryAfter, setEmployeePinRetryAfter] = useState<number | null>(null);

  const refresh = useCallback(async (options?: { clearFeedback?: boolean }) => {
    if (options?.clearFeedback !== false) {
      setError(null);
    }
    const meta = readStationMeta();
    try {
      const boot = await fetchStationBootstrap();
      writeStationMeta({
        device_id: boot.device_id,
        device_public_id: boot.device_public_id ?? meta?.device_public_id ?? "",
      });
      setConfigured(true);
      setBootstrap({
        name: boot.name,
        display_title: boot.display_title ?? null,
        display_logo_url: boot.display_logo_url ?? null,
        effective_display_title: boot.effective_display_title ?? boot.name,
        status: boot.status,
        location_path: boot.location_path,
        ready: boot.ready,
        device_public_id: boot.device_public_id ?? meta?.device_public_id,
        allowed_methods: boot.allowed_methods ?? ["manual"],
        geo_antifraud_enabled: boot.geo_antifraud_enabled ?? false,
        geo_antifraud_radius_m: boot.geo_antifraud_radius_m ?? 150,
        location_has_geo: boot.location_has_geo ?? false,
        entry_mode: boot.entry_mode ?? "employee_list",
        employee_list_layout: boot.employee_list_layout ?? "compact",
        document_match: boot.document_match === "exact" ? "exact" : "suffix",
        document_suffix_length: boot.document_suffix_length ?? 4,
        identity_confirm: boot.identity_confirm ?? "none",
        qr_identity_confirm: boot.qr_identity_confirm ?? "none",
        session_idle_seconds: boot.session_idle_seconds ?? 60,
        session_return_countdown_seconds: boot.session_return_countdown_seconds ?? 15,
        session_allow_history: boot.session_allow_history ?? false,
        session_history_max_days: boot.session_history_max_days ?? 90,
        ux_preset: boot.ux_preset ?? "custom",
        waiting_idle_seconds: boot.waiting_idle_seconds ?? 0,
        mask_names_on_waiting: boot.mask_names_on_waiting ?? false,
        offline_deferred_punch_enabled: boot.offline_deferred_punch_enabled ?? false,
        ops_lockdown: boot.ops_lockdown ?? false,
        config_version: boot.config_version ?? 1,
      });
      const methods = boot.allowed_methods ?? ["manual"];
      const allowManualBoot = methods.includes("manual");
      const allowQrBoot = methods.includes("qr") || methods.includes("barcode");
      setChannel((current) => {
        const preferred = defaultChannel(
          boot.entry_mode ?? "employee_list",
          allowManualBoot,
          allowQrBoot,
        );
        if (current === "document" && !allowManualBoot) return preferred;
        if (current === "manual" && !allowManualBoot) return preferred;
        if (current === "qr" && !allowQrBoot) return preferred;
        if (current === "document" && (boot.entry_mode ?? "employee_list") !== "document_entry") {
          return preferred;
        }
        return current || preferred;
      });
      if (boot.ready) {
        const [payload, pauses] = await Promise.all([
          fetchStationEmployees(),
          fetchStationPauseConfigs().catch(() => ({ configs: [] as StationPauseConfig[] })),
        ]);
        const rows = (payload.employees ?? []) as StationEmployeeRow[];
        setEmployees(rows);
        setPauseConfigs(pauses.configs ?? []);
        setAssignmentMode(payload.assignment_mode ?? null);
        syncEmployeeFromList(rows);
      } else {
        setEmployees([]);
        setPauseConfigs([]);
        setAssignmentMode(null);
        endSession();
      }
    } catch (err) {
      const code = err instanceof Error ? err.message : "station_load_failed";
      setError(formatStationPunchError(code));
      if (
        code.includes("station_not_found")
        || code.includes("missing_station_auth")
        || code.includes("station_invalid_secret")
        || code.includes("station_auth_failed")
        || code.includes("station_error")
      ) {
        await clearStationCredentials();
        setConfigured(false);
      }
    } finally {
      setLoading(false);
    }
  }, [syncEmployeeFromList, endSession]);

  useEffect(() => {
    if (
      !sessionEmployee
      || (phase !== "employee_session" && phase !== "success_flash")
    ) {
      return;
    }
    let cancelled = false;
    void (async () => {
      try {
        const hint = await fetchStationEmployeeLocationHint(sessionEmployee.employee_id);
        if (cancelled) return;
        patchSessionEmployee({
          scheduled_location_name: hint.scheduled_location_name,
          scheduled_location_path: hint.scheduled_location_path,
          wrong_scheduled_location: hint.wrong_scheduled_location,
          warn_wrong_scheduled_location: hint.warn_wrong_scheduled_location,
          outside_assignment: hint.outside_assignment,
          warn_unassigned_punch: hint.warn_unassigned_punch,
        });
      } catch {
        // Hint is best-effort; punch path still enforces warn/block.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [sessionEmployee?.employee_id, phase, patchSessionEmployee]);

  useEffect(() => {
    void (async () => {
      await migrateLegacyStationCredentials();
      await refresh();
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- boot once on mount
  }, []);

  useEffect(() => {
    if (!configured || loading) return;

    let cancelled = false;
    const sendHeartbeat = async () => {
      try {
        const hb = await postStationHeartbeat({
          pendingCount: stationSync.pendingCount,
          quarantinedCount: stationSync.quarantinedCount,
        });
        if (hb.last_seen_at) {
          await saveStationTemporalAnchor({
            server_anchor_at: hb.last_seen_at,
            client_anchor_at: new Date().toISOString(),
          });
        }
        if (typeof hb.ops_lockdown === "boolean") {
          setBootstrap((prev) =>
            prev
              ? {
                  ...prev,
                  ops_lockdown: hb.ops_lockdown,
                  config_version: hb.config_version ?? prev.config_version,
                }
              : prev,
          );
        }
      } catch {
        // Heartbeat is best-effort; bootstrap/refresh still touch last_seen.
      }
    };

    void sendHeartbeat();
    const timer = window.setInterval(() => {
      if (!cancelled) void sendHeartbeat();
    }, STATION_HEARTBEAT_INTERVAL_MS);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [configured, loading, stationSync.pendingCount, stationSync.quarantinedCount]);

  useEffect(() => {
    const onFullscreenChange = () => {
      setIsFullscreen(Boolean(document.fullscreenElement));
    };
    document.addEventListener("fullscreenchange", onFullscreenChange);
    return () => document.removeEventListener("fullscreenchange", onFullscreenChange);
  }, []);

  useEffect(() => {
    if (phase !== "waiting") {
      setPrivacyBlank(false);
      return;
    }
    const idleSeconds = bootstrap?.waiting_idle_seconds ?? 0;
    if (idleSeconds < 30) {
      setPrivacyBlank(false);
      return;
    }

    let timer = window.setTimeout(() => setPrivacyBlank(true), idleSeconds * 1000);
    const onActivity = () => {
      setPrivacyBlank((blank) => {
        if (blank) return blank;
        window.clearTimeout(timer);
        timer = window.setTimeout(() => setPrivacyBlank(true), idleSeconds * 1000);
        return false;
      });
    };
    const events: (keyof WindowEventMap)[] = ["pointerdown", "keydown", "touchstart"];
    for (const event of events) {
      window.addEventListener(event, onActivity);
    }
    return () => {
      window.clearTimeout(timer);
      for (const event of events) {
        window.removeEventListener(event, onActivity);
      }
    };
  }, [phase, bootstrap?.waiting_idle_seconds, waitingIdleNonce]);

  useEffect(() => {
    if (!menuOpen) return;

    const onPointerDown = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (document.querySelector("[data-station-admin-menu]")?.contains(target)) return;
      closeAdminMenu();
    };

    document.addEventListener("pointerdown", onPointerDown);
    return () => document.removeEventListener("pointerdown", onPointerDown);
  }, [menuOpen]);

  const allowedMethods = bootstrap?.allowed_methods ?? ["manual"];
  const allowManual = allowedMethods.includes("manual");
  const allowQr = allowedMethods.includes("qr") || allowedMethods.includes("barcode");

  const handleQrScan = useCallback(async (token: string) => {
    if (busy || phase !== "waiting") return;
    setBusy(true);
    setError(null);
    setDocumentError(null);
    setMessage(null);
    try {
      const resolved = await resolveStationIdentityToken(token);
      selectEmployee(
        {
          employee_id: resolved.employee_id,
          full_name: resolved.full_name,
          last_punch_type: null,
          last_punch_at: null,
          day_state: resolved.day_state as StationDayState,
          next_punch: resolved.next_punch,
        },
        "qr",
        token,
      );
    } catch (err) {
      setError(formatStationPunchError(err instanceof Error ? err.message : "identity_resolve_failed"));
    } finally {
      setBusy(false);
    }
  }, [busy, phase, selectEmployee]);

  const handleDocumentSubmit = useCallback(async (documentId: string) => {
    if (busy || phase !== "waiting") return;
    setBusy(true);
    setDocumentError(null);
    setError(null);
    setMessage(null);
    setAmbiguousMatches(null);
    try {
      const resolved = await resolveStationEmployeeDocument(documentId);
      if (resolved.status === "not_found") {
        setDocumentError("Document no reconegut. Torna-ho a provar.");
        return;
      }
      const matches = (resolved.matches ?? []).map((row) => ({
        employee_id: row.employee_id,
        full_name: row.full_name,
        last_punch_type: null,
        last_punch_at: null,
        day_state: (row.day_state ?? null) as StationDayState,
        next_punch: row.next_punch ?? null,
      }));
      if (resolved.status === "ambiguous" || matches.length > 1) {
        setAmbiguousMatches(matches);
        return;
      }
      const one = matches[0];
      if (!one) {
        setDocumentError("Document no reconegut. Torna-ho a provar.");
        return;
      }
      selectEmployee(one, "document");
    } catch (err) {
      const raw = err instanceof Error ? err.message : "document_resolve_failed";
      if (raw.includes("station_document_resolve_rate_limited")) {
        setDocumentError("Massa intents. Espera uns minuts i torna-ho a provar.");
      } else {
        setDocumentError(formatStationPunchError(raw));
      }
    } finally {
      setBusy(false);
    }
  }, [busy, phase, selectEmployee]);

  async function handleRegister(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      const result = await registerStation({
        pairing_code: pairingCode,
        local_pin: localPin,
        name: stationName || undefined,
      });
      writeStationMeta({
        device_id: result.device_id,
        device_public_id: result.device_public_id,
      });
      setMessage("Estació aparellada. Assigna centre i ubicació des del tenant-portal i activa-la.");
      setConfigured(true);
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "register_failed");
    } finally {
      setBusy(false);
    }
  }

  async function handlePunch(
    punchType: "in" | "out" | "break_start" | "break_end",
    pauseType?: string,
  ) {
    const selected = sessionEmployee;
    if (!selected) return;

    const dayState = selected.day_state ?? null;
    if (punchType === "in" || punchType === "out") {
      const selectedNextPunch = selected.next_punch ?? null;
      if (selectedNextPunch && selectedNextPunch !== punchType && selectedNextPunch !== "break_end") {
        setError(formatStationPunchError(`station_wrong_punch_type: expected ${selectedNextPunch} got ${punchType}`));
        return;
      }
      if (punchType === "out" && dayState !== "work") {
        setError(formatStationPunchError(`station_wrong_punch_type: expected for state ${dayState} got out`));
        return;
      }
    }
    if (punchType === "break_start" && dayState !== "work") {
      setError(formatStationPunchError(`station_wrong_punch_type: expected for state ${dayState} got break_start`));
      return;
    }
    if (punchType === "break_end" && dayState !== "break") {
      setError(formatStationPunchError(`station_wrong_punch_type: expected for state ${dayState} got break_end`));
      return;
    }
    if (punchType === "break_start" && !pauseType) {
      setError(formatStationPunchError("missing_pause_type"));
      return;
    }

    const meta = readStationMeta();
    if (!meta?.device_id) {
      setError(formatStationPunchError("station_not_ready"));
      return;
    }

    setBusy(true);
    setError(null);
    setMessage(null);

    const clientOpId = generateClientOpId();
    const occurredAt = new Date().toISOString();
    const onlineSource = selected.identitySource === "qr" ? "qr" : "station";

    try {
      let deviceGeo:
        | {
            latitude: number;
            longitude: number;
            accuracy_meters?: number;
            timestamp: string;
          }
        | undefined;
      if (bootstrap?.geo_antifraud_enabled) {
        try {
          deviceGeo = await getStationDeviceGeo();
        } catch (geoErr) {
          setError(formatStationGeoError(geoErr instanceof Error ? geoErr.message : "station_geo_unavailable"));
          return;
        }
      }

      const applyLocalSuccess = (
        occurredAtResult: string,
        extras?: {
          location_name?: string;
          wrong_scheduled_location?: boolean;
          scheduled_location_path?: string | null;
          scheduled_location_name?: string | null;
          outside_assignment?: boolean;
          queuedLocally?: boolean;
        },
      ) => {
        const actionLabel =
          punchType === "in"
            ? "Entrada"
            : punchType === "out"
              ? "Sortida"
              : punchType === "break_start"
                ? "Pausa iniciada"
                : "Pausa tancada";

        const offlineSuffix = extras?.queuedLocally ? " (desat localment)" : "";
        const flash = `${selected.full_name}: ${actionLabel}${
          extras?.location_name ? ` a ${extras.location_name}` : ""
        }${
          extras?.wrong_scheduled_location
            ? ` — avís: et tocava a ${
              extras.scheduled_location_path
                || extras.scheduled_location_name
                || "una altra ubicació"
            }`
            : ""
        }${offlineSuffix}.`;

        const nextState =
          punchType === "in"
            ? "work"
            : punchType === "out"
              ? "day"
              : punchType === "break_start"
                ? "break"
                : "work";

        const nextPunch =
          nextState === "work"
            ? "out"
            : nextState === "break"
              ? "break_end"
              : nextState === "off" || nextState === "day"
                ? "in"
                : null;

        notePunchSuccess(flash, {
          ...selected,
          last_punch_type: punchType,
          last_punch_at: occurredAtResult,
          next_punch: nextPunch,
          day_state: nextState,
          active_pause_type: punchType === "break_start" ? pauseType ?? null : null,
          can_start_pause: nextState === "work",
          can_end_pause: nextState === "break",
          identityToken: null,
          scheduled_location_name: extras?.scheduled_location_name ?? selected.scheduled_location_name,
          scheduled_location_path: extras?.scheduled_location_path ?? selected.scheduled_location_path,
          wrong_scheduled_location: extras?.wrong_scheduled_location ?? selected.wrong_scheduled_location,
          outside_assignment: extras?.outside_assignment ?? selected.outside_assignment,
        });
      };

      const enqueueOffline = async () => {
        if (!bootstrap?.offline_deferred_punch_enabled) {
          setError(
            "Sense connexió no es pot fitxar en aquesta estació. Reconnecta la xarxa o contacta administració.",
          );
          return;
        }
        await saveStationPunchOpLocally({
          client_op_id: clientOpId,
          device_id: meta.device_id,
          employee_id: selected.employee_id,
          employee_name: selected.full_name,
          punch_type: punchType,
          pause_type: pauseType ?? null,
          occurred_at: occurredAt,
          source: "station",
          device_geo: deviceGeo ?? null,
        });
        await stationSync.refreshCounts();
        applyLocalSuccess(occurredAt, { queuedLocally: true });
        setMessage("Fitxatge desat localment — es pujarà en tornar la connexió.");
      };

      if (!navigator.onLine) {
        await enqueueOffline();
        return;
      }

      try {
        const result = await postStationPunch({
          employee_id: selected.employee_id,
          punch_type: punchType,
          pause_type: pauseType,
          source: onlineSource,
          identity_token: onlineSource === "qr" ? selected.identityToken ?? undefined : undefined,
          client_op_id: clientOpId,
          device_geo: deviceGeo,
        });

        applyLocalSuccess(result.occurred_at ?? occurredAt, {
          location_name: result.location_name,
          wrong_scheduled_location: result.wrong_scheduled_location,
          scheduled_location_path: result.scheduled_location_path,
          scheduled_location_name: result.scheduled_location_name,
          outside_assignment: result.outside_assignment,
        });
        await refresh({ clearFeedback: false });
      } catch (err) {
        if (isStationNetworkFailure(err)) {
          await enqueueOffline();
          return;
        }
        throw err;
      }
    } catch (err) {
      const raw = err instanceof Error ? err.message : "punch_failed";
      setError(
        bootstrap?.geo_antifraud_enabled
          ? formatStationGeoError(raw)
          : formatStationPunchError(raw),
      );
    } finally {
      setBusy(false);
    }
  }

  function openAdminMenu() {
    setMenuOpen(false);
    setPinModalAction("adminMenu");
    setPinModalError(null);
    setPinModalRetryAfter(null);
  }

  function closeAdminMenu() {
    setMenuOpen(false);
  }

  function closePinModal() {
    setPinModalAction(null);
    setPinModalError(null);
    setPinModalRetryAfter(null);
  }

  async function handleSensitivePin(pin: string) {
    try {
      await verifyStationLocalPin(pin);
      if (pinModalAction === "adminMenu") {
        closePinModal();
        setMenuOpen(true);
        return;
      }
      closePinModal();
    } catch (err) {
      const code = err instanceof Error ? err.message : "station_pin_invalid";
      const parsed = parseStationPinError(code);
      if (err instanceof Error && "retryAfterSeconds" in err && typeof err.retryAfterSeconds === "number") {
        parsed.retryAfterSeconds = err.retryAfterSeconds;
      }
      setPinModalError(parsed.code);
      setPinModalRetryAfter(parsed.retryAfterSeconds);
      throw err;
    }
  }

  function handleAdminLock() {
    closeAdminMenu();
    endSession();
    setSearch("");
    manualLock.lock();
  }

  async function handleAdminUnpair() {
    closeAdminMenu();
    await clearStationOutbox();
    await clearStationCredentials();
    setConfigured(false);
    setBootstrap(null);
    setEmployees([]);
    endSession();
    setMessage(null);
    setError(null);
  }

  async function handleAdminExitFullscreen() {
    closeAdminMenu();
    if (document.fullscreenElement) {
      await document.exitFullscreen();
    }
  }

  function handleFullscreenClick() {
    if (isFullscreen) {
      openAdminMenu();
      return;
    }
    void document.documentElement.requestFullscreen().catch(() => {
      setError("No s'ha pogut activar el mode pantalla completa.");
    });
  }

  if (loading) {
    return <main className="mx-auto max-w-3xl p-6 text-muted-foreground">Carregant estació…</main>;
  }

  if (!configured) {
    return (
      <main className="mx-auto max-w-md space-y-6 p-6">
        <div>
          <h1 className="text-2xl font-semibold">Estació de fitxatge</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Introdueix el codi d&apos;aparellament generat al tenant-portal i defineix un PIN local
            per protegir accions sensibles del kiosk (no per fitxar).
          </p>
        </div>
        <form className="space-y-4 rounded-2xl border p-4" onSubmit={handleRegister}>
          <label className="block space-y-1 text-sm">
            <span>Codi d&apos;aparellament</span>
            <input
              className="w-full rounded-md border px-3 py-2 font-mono uppercase tracking-widest"
              value={pairingCode}
              onChange={(e) => setPairingCode(e.target.value.toUpperCase())}
              required
            />
          </label>
          <div className="space-y-2">
            <button
              type="button"
              className="w-full rounded-md border px-4 py-2 text-sm"
              onClick={() => setShowPairingQrScan((v) => !v)}
            >
              {showPairingQrScan ? "Amagar escàner QR" : "Escanejar QR d'aparellament"}
            </button>
            {showPairingQrScan ? (
              <StationQrScanner
                onScan={(raw) => {
                  const cleaned = raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
                  if (cleaned.length >= 4) {
                    setPairingCode(cleaned);
                    setShowPairingQrScan(false);
                  }
                }}
                disabled={busy}
                manualAvailable={false}
              />
            ) : null}
          </div>
          <label className="block space-y-1 text-sm">
            <span>PIN local (4-6 dígits)</span>
            <input
              className="w-full rounded-md border px-3 py-2"
              inputMode="numeric"
              pattern="\d{4,6}"
              value={localPin}
              onChange={(e) => setLocalPin(e.target.value)}
              required
            />
          </label>
          <label className="block space-y-1 text-sm">
            <span>Nom de l&apos;estació (opcional)</span>
            <input
              className="w-full rounded-md border px-3 py-2"
              value={stationName}
              onChange={(e) => setStationName(e.target.value)}
            />
          </label>
          {error ? <p className="text-sm text-destructive">{error}</p> : null}
          <button
            type="submit"
            disabled={busy}
            className="w-full rounded-md bg-primary px-4 py-3 text-primary-foreground disabled:opacity-50"
          >
            Aparellar estació
          </button>
        </form>
      </main>
    );
  }

  if (manualLock.isManuallyLocked) {
    const lockedTitle =
      bootstrap?.effective_display_title ?? bootstrap?.name ?? "Estació de fitxatge";
    return (
      <main className="flex min-h-[100dvh] flex-col justify-center bg-background">
        <div className="mx-auto max-w-lg space-y-4 px-4 text-center">
          <StationBrandingHeader
            title={lockedTitle}
            logoUrl={bootstrap?.display_logo_url}
            subtitle="Bloqueig manual — només personal autoritzat pot desbloquejar"
            compact
          />
        </div>
        <StationPinPad
          title="Estació bloquejada"
          subtitle="PIN local per desbloquejar (no cal per fitxar en ús normal)"
          onSubmit={manualLock.unlock}
          errorCode={manualLock.pinError}
          retryAfterSeconds={manualLock.retryAfterSeconds}
        />
      </main>
    );
  }

  const pinModalCopy =
    pinModalAction === "adminMenu"
      ? {
          title: "Accions d'administració",
          subtitle: "Introdueix el PIN local per accedir a les opcions de l'estació.",
          submitLabel: "Continuar",
        }
      : null;

  const stationTitle = bootstrap?.effective_display_title ?? bootstrap?.name ?? "Estació";
  const stationLocationSubtitle = bootstrap?.location_path
    ? `Ubicació: ${bootstrap.location_path}`
    : "Sense ubicació assignada — contacta amb administració.";

  const inSession =
    phase === "employee_session"
    || phase === "success_flash"
    || phase === "history_pin"
    || phase === "history";

  return (
    <main className="mx-auto max-w-4xl space-y-4 p-4 md:p-6">
      {privacyBlank && phase === "waiting" ? (
        <StationPrivacyBlank
          title={stationTitle}
          logoUrl={bootstrap?.display_logo_url}
          onWake={() => {
            setPrivacyBlank(false);
            setWaitingIdleNonce((n) => n + 1);
          }}
        />
      ) : null}
      <div aria-live="polite" className="sr-only">
        {message ?? error ?? flashMessage ?? ""}
      </div>
      <header className="rounded-2xl border p-4">
        <div className="flex items-start justify-between gap-3">
          <StationBrandingHeader
            title={stationTitle}
            logoUrl={bootstrap?.display_logo_url}
            subtitle={stationLocationSubtitle}
            meta={`Estat: ${bootstrap?.status ?? "—"}`}
          />
          <div className="flex shrink-0 items-center gap-2">
            <button
              type="button"
              className="rounded-lg border px-3 py-2 text-sm hover:bg-muted"
              onClick={handleFullscreenClick}
              title={isFullscreen ? "Sortir de pantalla completa (PIN)" : "Pantalla completa"}
              aria-label={isFullscreen ? "Sortir de pantalla completa" : "Pantalla completa"}
            >
              ⛶
            </button>
            <div className="relative" data-station-admin-menu>
              <button
                type="button"
                className="rounded-lg border px-3 py-2 text-sm hover:bg-muted"
                onClick={openAdminMenu}
                aria-expanded={menuOpen}
                aria-haspopup="menu"
              >
                Administració
              </button>
              {menuOpen ? (
                <div className="absolute right-0 z-30 mt-2 min-w-[14rem] rounded-xl border bg-background p-2 shadow-lg">
                  <p className="px-3 py-1 text-xs text-muted-foreground">Només personal autoritzat</p>
                  <button
                    type="button"
                    className="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-muted"
                    onClick={handleAdminLock}
                  >
                    Bloquejar estació
                  </button>
                  {isFullscreen ? (
                    <button
                      type="button"
                      className="block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-muted"
                      onClick={() => void handleAdminExitFullscreen()}
                    >
                      Sortir pantalla completa
                    </button>
                  ) : null}
                  <button
                    type="button"
                    className="block w-full rounded-lg px-3 py-2 text-left text-sm text-destructive hover:bg-destructive/10"
                    onClick={handleAdminUnpair}
                  >
                    Desaparellar estació
                  </button>
                  <button
                    type="button"
                    className="mt-1 block w-full rounded-lg border-t px-3 py-2 text-left text-xs text-muted-foreground hover:bg-muted"
                    onClick={closeAdminMenu}
                  >
                    Tancar
                  </button>
                </div>
              ) : null}
            </div>
          </div>
        </div>
      </header>

      {bootstrap?.ops_lockdown ? (
        <div
          className="rounded-2xl border border-red-400 bg-red-50 p-3 text-sm text-red-950"
          role="alert"
        >
          Estació en lockdown operatiu: els fitxatges estan bloquejats fins que un administrador
          ho desactivi al tenant-portal.
        </div>
      ) : null}

      {stationSync.pendingCount > 0 || stationSync.quarantinedCount > 0 || !stationSync.isOnline ? (
        <div
          className={`rounded-2xl border p-3 text-sm ${
            stationSync.quarantinedCount > 0
              ? "border-amber-400 bg-amber-50 text-amber-950"
              : !stationSync.isOnline
                ? "border-slate-300 bg-slate-50 text-slate-800"
                : "border-sky-300 bg-sky-50 text-sky-950"
          }`}
          role="status"
        >
          {!stationSync.isOnline
            ? bootstrap?.offline_deferred_punch_enabled
              ? "Sense connexió — els fitxatges es desen localment."
              : "Sense connexió — cal xarxa per fitxar (offline no actiu)."
            : null}
          {stationSync.pendingCount > 0
            ? `${!stationSync.isOnline ? " " : ""}${stationSync.pendingCount} fitxatge(s) pendent(s) de pujar${
              stationSync.isSyncing ? " (sincronitzant…)" : ""
            }.`
            : null}
          {stationSync.quarantinedCount > 0
            ? ` ${stationSync.quarantinedCount} en quarantena (cal revisió).`
            : null}
        </div>
      ) : null}

      {!bootstrap?.ready ? (
        <div className="rounded-2xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
          L&apos;estació encara no està activa. Un administrador ha d&apos;assignar centre i ubicació
          des de Configuració → Estacions de fitxatge.
        </div>
      ) : phase === "confirm_identity" && pending ? (
        <div className="space-y-4 rounded-2xl border p-6 text-center">
          <p className="text-sm text-muted-foreground">Confirmació d&apos;identitat</p>
          <h2 className="text-3xl font-semibold">Ets {pending.full_name}?</h2>
          <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
            <button
              type="button"
              className="rounded-xl bg-primary px-6 py-4 text-lg font-semibold text-primary-foreground"
              onClick={confirmIdentity}
            >
              Sí, sóc jo
            </button>
            <button
              type="button"
              className="rounded-xl border px-6 py-4 text-lg font-medium hover:bg-muted"
              onClick={cancelConfirm}
            >
              No
            </button>
          </div>
        </div>
      ) : phase === "confirm_pin" && pending ? (
        <div className="space-y-4 rounded-2xl border p-4">
          <div className="text-center">
            <p className="text-sm text-muted-foreground">Verificació amb PIN</p>
            <h2 className="text-2xl font-semibold">{pending.full_name}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Introdueix el teu PIN del portal d&apos;empleat
            </p>
          </div>
          <StationPinPad
            title="PIN d'empleat"
            subtitle="El mateix PIN que uses al portal (4–6 dígits)"
            submitLabel="Confirmar"
            errorCode={employeePinError}
            retryAfterSeconds={employeePinRetryAfter}
            onSubmit={async (pin) => {
              setEmployeePinError(null);
              setEmployeePinRetryAfter(null);
              try {
                const result = await verifyStationEmployeePin(pending.employee_id, pin);
                if (result.status === "ok") {
                  confirmPinSuccess();
                  return;
                }
                if (result.status === "no_pin") {
                  fallbackPinToTapName();
                  return;
                }
                setEmployeePinError("invalid");
                throw new Error("station_employee_pin_invalid");
              } catch (err) {
                const code = err instanceof Error ? err.message : "";
                if (code.includes("station_employee_pin_locked")) {
                  setEmployeePinError("locked");
                  if (
                    err instanceof Error
                    && typeof (err as Error & { retryAfterSeconds?: number }).retryAfterSeconds === "number"
                  ) {
                    setEmployeePinRetryAfter(
                      (err as Error & { retryAfterSeconds: number }).retryAfterSeconds,
                    );
                  } else {
                    setEmployeePinRetryAfter(900);
                  }
                } else {
                  setEmployeePinError("invalid");
                }
                throw err;
              }
            }}
          />
          <button
            type="button"
            className="w-full rounded-xl border px-4 py-3 text-sm hover:bg-muted"
            onClick={() => {
              setEmployeePinError(null);
              setEmployeePinRetryAfter(null);
              cancelConfirm();
            }}
          >
            Cancel·lar
          </button>
        </div>
      ) : phase === "history_pin" && sessionEmployee ? (
        <div className="space-y-4 rounded-2xl border p-4">
          <div className="text-center">
            <p className="text-sm text-muted-foreground">Historial — verificació</p>
            <h2 className="text-2xl font-semibold">{sessionEmployee.full_name}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Introdueix el PIN del portal per consultar els teus fitxatges
            </p>
          </div>
          <StationPinPad
            title="PIN per l'historial"
            subtitle="Reautenticació obligatòria (4–6 dígits)"
            submitLabel="Veure historial"
            errorCode={employeePinError}
            retryAfterSeconds={employeePinRetryAfter}
            onSubmit={async (pin) => {
              setEmployeePinError(null);
              setEmployeePinRetryAfter(null);
              try {
                const result = await verifyStationEmployeePin(sessionEmployee.employee_id, pin);
                if (result.status === "ok") {
                  confirmHistoryPin(pin);
                  return;
                }
                if (result.status === "no_pin") {
                  setError(
                    "Cal tenir un PIN del portal configurat per consultar l'historial a l'estació.",
                  );
                  closeHistory();
                  return;
                }
                setEmployeePinError("invalid");
                throw new Error("station_employee_pin_invalid");
              } catch (err) {
                const code = err instanceof Error ? err.message : "";
                if (code.includes("station_employee_pin_locked")) {
                  setEmployeePinError("locked");
                  if (
                    err instanceof Error
                    && typeof (err as Error & { retryAfterSeconds?: number }).retryAfterSeconds === "number"
                  ) {
                    setEmployeePinRetryAfter(
                      (err as Error & { retryAfterSeconds: number }).retryAfterSeconds,
                    );
                  } else {
                    setEmployeePinRetryAfter(900);
                  }
                } else {
                  setEmployeePinError("invalid");
                }
                throw err;
              }
            }}
          />
          <button
            type="button"
            className="w-full rounded-xl border px-4 py-3 text-sm hover:bg-muted"
            onClick={() => {
              setEmployeePinError(null);
              setEmployeePinRetryAfter(null);
              setError(null);
              closeHistory();
            }}
          >
            Tornar a fitxar
          </button>
        </div>
      ) : phase === "history" && sessionEmployee && historyPin ? (
        <StationEmployeeHistoryView
          employeeId={sessionEmployee.employee_id}
          employeeName={sessionEmployee.full_name}
          maxDays={bootstrap.session_history_max_days}
          unlockedPin={historyPin}
          busy={busy}
          onBack={() => {
            setError(null);
            closeHistory();
          }}
          onInteract={touchActivity}
          onEndSession={() => {
            endSession();
            setSearch("");
            setError(null);
          }}
        />
      ) : inSession && sessionEmployee ? (
        <StationEmployeeSessionView
          employee={sessionEmployee}
          phase={phase === "success_flash" ? "success_flash" : "employee_session"}
          flashMessage={flashMessage}
          countdownRemaining={countdownRemaining}
          countdownTotal={bootstrap.session_return_countdown_seconds}
          busy={busy}
          error={error}
          allowHistory={bootstrap.session_allow_history}
          pauseConfigs={pauseConfigs}
          onEndSession={() => {
            endSession();
            setSearch("");
            setError(null);
          }}
          onPunch={(punchType, pauseType) => void handlePunch(punchType, pauseType)}
          onOpenHistory={() => {
            setError(null);
            setEmployeePinError(null);
            setEmployeePinRetryAfter(null);
            openHistory();
          }}
          onInteract={touchActivity}
        />
      ) : (
        <StationWaitingView
          entryMode={bootstrap.entry_mode}
          listLayout={bootstrap.employee_list_layout}
          allowManual={allowManual}
          allowQr={allowQr}
          channel={channel}
          onChannelChange={(next) => {
            setChannel(next);
            setError(null);
            setDocumentError(null);
            setAmbiguousMatches(null);
            setSearch("");
          }}
          search={search}
          onSearchChange={setSearch}
          employees={employees}
          assignmentMode={assignmentMode}
          busy={busy}
          documentMatch={bootstrap.document_match}
          documentSuffixLength={bootstrap.document_suffix_length}
          documentError={documentError}
          ambiguousMatches={ambiguousMatches}
          onDocumentSubmit={(doc) => void handleDocumentSubmit(doc)}
          onClearAmbiguous={() => {
            setAmbiguousMatches(null);
            setDocumentError(null);
          }}
          onSelectEmployee={(employee) => {
            setError(null);
            setMessage(null);
            setDocumentError(null);
            const fromDocument = Boolean(ambiguousMatches?.length);
            setAmbiguousMatches(null);
            selectEmployee(employee, fromDocument ? "document" : "list");
          }}
          onQrScan={(token) => void handleQrScan(token)}
          maskNames={bootstrap.mask_names_on_waiting}
          onUserActivity={() => {
            if (privacyBlank) setPrivacyBlank(false);
          }}
        />
      )}

      {message && phase === "waiting" ? (
        <p className="rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm">{message}</p>
      ) : null}
      {phase === "waiting" && error ? (
        <p className="rounded-xl border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      {pinModalAction && pinModalCopy ? (
        <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 p-4 sm:items-center">
          <div className="w-full max-w-md rounded-2xl border bg-background p-4 shadow-xl">
            <div className="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 className="text-lg font-semibold">{pinModalCopy.title}</h2>
                <p className="mt-1 text-sm text-muted-foreground">{pinModalCopy.subtitle}</p>
              </div>
              <button
                type="button"
                className="rounded-lg border px-2 py-1 text-sm"
                onClick={closePinModal}
              >
                Tancar
              </button>
            </div>
            <StationPinPad
              title="Confirma el PIN"
              subtitle="Només per personal autoritzat"
              submitLabel={pinModalCopy.submitLabel}
              onSubmit={handleSensitivePin}
              errorCode={pinModalError}
              retryAfterSeconds={pinModalRetryAfter}
            />
          </div>
        </div>
      ) : null}
    </main>
  );
}
