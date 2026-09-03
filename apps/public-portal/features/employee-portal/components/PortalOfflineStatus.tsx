"use client";

import { useTranslation } from "react-i18next";

interface PortalOfflineStatusProps {
  isOnline: boolean;
  pendingCount: number;
  quarantinedCount: number;
  isSyncing: boolean;
}

export function PortalOfflineStatus({
  isOnline,
  pendingCount,
  quarantinedCount,
  isSyncing,
}: PortalOfflineStatusProps) {
  const { t } = useTranslation("portal");

  if (isOnline && pendingCount === 0 && quarantinedCount === 0) {
    return null;
  }

  return (
    <div className="space-y-2 text-sm">
      {!isOnline && (
        <p className="rounded-md border border-amber-500/40 bg-amber-50 px-3 py-2 text-amber-900 dark:bg-amber-950/30 dark:text-amber-100">
          {t("employee_portal.offline_banner", "Sense connexió — els fitxatges es desaran localment")}
        </p>
      )}
      {pendingCount > 0 && (
        <p className="text-muted-foreground text-center">
          {isSyncing
            ? t("employee_portal.syncing", "Sincronitzant fitxatges…")
            : t("employee_portal.pending_count", "{{count}} fitxatge(s) pendent(s)", {
                count: pendingCount,
              })}
        </p>
      )}
      {quarantinedCount > 0 && (
        <p className="text-destructive text-center" role="alert">
          {t(
            "employee_portal.quarantined_message",
            "Token revocat o error persistent. Contacta el teu responsable.",
          )}
        </p>
      )}
    </div>
  );
}
