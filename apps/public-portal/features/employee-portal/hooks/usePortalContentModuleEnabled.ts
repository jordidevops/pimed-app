"use client";

import { useEffect, useState } from "react";
import { EMPLOYEE_PORTAL_API_BASE } from "@/lib/employee-portal/constants";

const STORAGE_KEY = "employee_portal_content_module";

function readCached(): boolean | null {
  if (typeof sessionStorage === "undefined") return null;
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (raw === "1") return true;
  if (raw === "0") return false;
  return null;
}

function writeCached(enabled: boolean): void {
  if (typeof sessionStorage === "undefined") return;
  sessionStorage.setItem(STORAGE_KEY, enabled ? "1" : "0");
}

async function probeContentModule(): Promise<boolean> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/content`, {
    credentials: "include",
    cache: "no-store",
  });

  if (response.status === 403) {
    const body = await response.json().catch(() => ({}));
    const code = (body as { error?: { code?: string } }).error?.code;
    if (code === "content_module_disabled") {
      return false;
    }
  }

  return response.ok;
}

export function usePortalContentModuleEnabled(): boolean {
  const [enabled, setEnabled] = useState(() => readCached() ?? false);

  useEffect(() => {
    const cached = readCached();
    if (cached !== null) {
      setEnabled(cached);
      return;
    }

    let cancelled = false;
    void probeContentModule()
      .then((value) => {
        if (cancelled) return;
        writeCached(value);
        setEnabled(value);
      })
      .catch(() => {
        if (cancelled) return;
        writeCached(false);
        setEnabled(false);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  return enabled;
}
