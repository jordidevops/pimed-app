"use client";

import { StationQrScanner } from "@/components/station/StationQrScanner";
import { StationDocumentPad } from "@/components/station/StationDocumentPad";
import {
  stationDayStateLabel,
  type StationDayState,
  type StationEmployeeRow,
} from "@/lib/attendance-station/punchUi";
import type { StationEntryMode, StationListLayout } from "@/lib/attendance-station/client";
import { maskStationDisplayName } from "@/lib/attendance-station/stationUxPresets";

export type WaitingChannel = "document" | "manual" | "qr";

type Props = {
  entryMode: StationEntryMode;
  listLayout: StationListLayout;
  allowManual: boolean;
  allowQr: boolean;
  channel: WaitingChannel;
  onChannelChange: (channel: WaitingChannel) => void;
  search: string;
  onSearchChange: (value: string) => void;
  employees: StationEmployeeRow[];
  assignmentMode: "zone" | "site_fallback" | null;
  busy: boolean;
  documentMatch: "exact" | "suffix";
  documentSuffixLength: number;
  documentError?: string | null;
  ambiguousMatches?: StationEmployeeRow[] | null;
  onDocumentSubmit: (documentId: string) => void;
  onSelectEmployee: (employee: StationEmployeeRow) => void;
  onClearAmbiguous: () => void;
  onQrScan: (token: string) => void;
  maskNames?: boolean;
  onUserActivity?: () => void;
};

export function StationWaitingView({
  entryMode,
  listLayout,
  allowManual,
  allowQr,
  channel,
  onChannelChange,
  search,
  onSearchChange,
  employees,
  assignmentMode,
  busy,
  documentMatch,
  documentSuffixLength,
  documentError,
  ambiguousMatches,
  onDocumentSubmit,
  onSelectEmployee,
  onClearAmbiguous,
  onQrScan,
  maskNames = false,
  onUserActivity,
}: Props) {
  const displayName = (name: string) => (maskNames ? maskStationDisplayName(name) : name);

  const filtered = (() => {
    const q = search.trim().toLowerCase();
    if (!q) return employees;
    return employees.filter((e) => e.full_name.toLowerCase().includes(q));
  })();

  const showDocument = entryMode === "document_entry" && allowManual;
  const showList = allowManual && (entryMode === "employee_list" || entryMode === "document_entry");
  const showQr = allowQr;

  const channelTabs: Array<{ id: WaitingChannel; label: string; enabled: boolean }> = [
    { id: "document", label: "Document", enabled: showDocument },
    { id: "manual", label: "Llista", enabled: showList && (entryMode === "employee_list" || showDocument) },
    { id: "qr", label: "QR", enabled: showQr },
  ].filter((tab) => tab.enabled);

  const gridClass =
    listLayout === "two_column"
      ? "grid gap-3 sm:grid-cols-2"
      : listLayout === "search_first"
        ? "grid gap-3"
        : "grid gap-3 sm:grid-cols-2";

  if (ambiguousMatches && ambiguousMatches.length > 1) {
    return (
      <div className="space-y-4" onPointerDown={onUserActivity} onKeyDown={onUserActivity}>
        <div className="rounded-2xl border p-4">
          <p className="text-sm text-muted-foreground">Diverses coincidències</p>
          <h2 className="text-xl font-semibold">Quin ets tu?</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            El document coincideix amb més d&apos;un empleat. Tria el teu nom.
          </p>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          {ambiguousMatches.map((employee) => (
            <button
              key={employee.employee_id}
              type="button"
              disabled={busy}
              onClick={() => onSelectEmployee(employee)}
              className="min-h-12 rounded-2xl border p-4 text-left transition hover:border-primary/40 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary disabled:opacity-50"
            >
              <div className="text-lg font-medium">{displayName(employee.full_name)}</div>
              <div className="mt-1 text-xs text-muted-foreground">
                {stationDayStateLabel(employee.day_state as StationDayState | null)}
              </div>
            </button>
          ))}
        </div>
        <button
          type="button"
          className="min-h-12 w-full rounded-xl border px-4 py-3 text-sm hover:bg-muted"
          onClick={onClearAmbiguous}
        >
          Tornar a introduir document
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-4" onPointerDown={onUserActivity} onKeyDown={onUserActivity}>
      {channelTabs.length > 1 ? (
        <div className="flex gap-2 rounded-xl border p-1" role="tablist" aria-label="Canal d'identificació">
          {channelTabs.map((tab) => (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={channel === tab.id}
              className={`min-h-12 flex-1 rounded-lg px-4 py-2 text-sm font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary ${
                channel === tab.id ? "bg-primary text-primary-foreground" : "hover:bg-muted"
              }`}
              onClick={() => onChannelChange(tab.id)}
            >
              {tab.label}
            </button>
          ))}
        </div>
      ) : null}

      {channel === "document" && showDocument ? (
        <StationDocumentPad
          disabled={busy}
          minLength={documentSuffixLength}
          matchMode={documentMatch}
          onSubmit={onDocumentSubmit}
          error={documentError}
        />
      ) : channel === "qr" && showQr ? (
        <StationQrScanner
          onScan={onQrScan}
          disabled={busy}
          manualAvailable={showList || showDocument}
        />
      ) : showList ? (
        <>
          <input
            className="min-h-12 w-full rounded-xl border px-4 py-3 text-lg"
            placeholder="Cerca empleat…"
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            autoFocus={listLayout === "search_first"}
            aria-label="Cerca empleat"
          />

          {assignmentMode === "site_fallback" ? (
            <p className="rounded-xl border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-900">
              Sense assignacions de zona configurades: es mostren tots els empleats actius del centre.
            </p>
          ) : null}

          <div className={gridClass}>
            {filtered.map((employee) => (
              <button
                key={employee.employee_id}
                type="button"
                onClick={() => onSelectEmployee(employee)}
                className="min-h-12 rounded-2xl border p-4 text-left transition hover:border-primary/40 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                <div className="text-lg font-medium">{displayName(employee.full_name)}</div>
                <div className="mt-1 text-xs text-muted-foreground">
                  {stationDayStateLabel(employee.day_state as StationDayState | null)}
                  {!maskNames && employee.last_punch_type ? ` · darrer: ${employee.last_punch_type}` : ""}
                  {!maskNames && employee.last_punch_at
                    ? ` (${new Date(employee.last_punch_at).toLocaleTimeString()})`
                    : ""}
                </div>
              </button>
            ))}
          </div>
        </>
      ) : showQr ? (
        <StationQrScanner onScan={onQrScan} disabled={busy} manualAvailable={false} />
      ) : (
        <div className="rounded-2xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
          Aquesta estació no té cap mètode de fitxatge habilitat. Contacta amb administració.
        </div>
      )}
    </div>
  );
}
