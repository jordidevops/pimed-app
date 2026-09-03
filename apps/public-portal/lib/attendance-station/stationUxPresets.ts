export type StationUxPreset = "custom" | "estricte" | "rapid_supervisat" | "qr";

export type StationUxPresetBundle = {
  entryMode: "employee_list" | "document_entry";
  listLayout: "compact" | "two_column" | "search_first";
  documentMatch: "exact" | "suffix";
  documentSuffixLength: number;
  identityConfirm: "none" | "tap_name" | "portal_pin";
  qrIdentityConfirm: "none" | "tap_name" | "portal_pin";
  sessionIdleSeconds: number;
  sessionCountdownSeconds: number;
  sessionAllowHistory: boolean;
  waitingIdleSeconds: number;
  maskNamesOnWaiting: boolean;
  forceAllowedMethods?: ("manual" | "qr")[];
};

export const STATION_UX_PRESET_LABELS: Record<StationUxPreset, string> = {
  custom: "Personalitzat",
  estricte: "Estricte (vestuari)",
  rapid_supervisat: "Ràpid supervisat",
  qr: "Només QR",
};

export const STATION_UX_PRESETS: Record<Exclude<StationUxPreset, "custom">, StationUxPresetBundle> = {
  estricte: {
    entryMode: "document_entry",
    listLayout: "search_first",
    documentMatch: "suffix",
    documentSuffixLength: 4,
    identityConfirm: "tap_name",
    qrIdentityConfirm: "tap_name",
    sessionIdleSeconds: 45,
    sessionCountdownSeconds: 10,
    sessionAllowHistory: false,
    waitingIdleSeconds: 90,
    maskNamesOnWaiting: true,
  },
  rapid_supervisat: {
    entryMode: "employee_list",
    listLayout: "two_column",
    documentMatch: "suffix",
    documentSuffixLength: 4,
    identityConfirm: "tap_name",
    qrIdentityConfirm: "none",
    sessionIdleSeconds: 90,
    sessionCountdownSeconds: 15,
    sessionAllowHistory: false,
    waitingIdleSeconds: 180,
    maskNamesOnWaiting: false,
  },
  qr: {
    entryMode: "document_entry",
    listLayout: "compact",
    documentMatch: "suffix",
    documentSuffixLength: 4,
    identityConfirm: "tap_name",
    qrIdentityConfirm: "tap_name",
    sessionIdleSeconds: 60,
    sessionCountdownSeconds: 12,
    sessionAllowHistory: false,
    waitingIdleSeconds: 120,
    maskNamesOnWaiting: true,
    forceAllowedMethods: ["qr"],
  },
};

/** Mask PII on shared waiting screens (IN-08). */
export function maskStationDisplayName(fullName: string): string {
  const parts = fullName.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "—";
  return parts
    .map((part) => {
      const first = part.charAt(0);
      if (part.length <= 1) return first;
      return `${first}***`;
    })
    .join(" ");
}
