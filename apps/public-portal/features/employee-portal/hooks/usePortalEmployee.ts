"use client";

import { useEffect, useState } from "react";
import { fetchPortalMe, type PortalEmployee } from "../api/portalApi";
import { readPortalEmployeeSnapshot } from "@/lib/employee-portal/sessionFlags";

function snapshotToEmployee(): PortalEmployee | null {
  const snap = readPortalEmployeeSnapshot();
  if (!snap) return null;
  return {
    id: snap.id,
    tenant_id: snap.tenant_id,
    full_name: snap.full_name,
    pin_required: snap.pin_required,
    work_profile: snap.work_profile,
    legacy_in_out_only: snap.legacy_in_out_only,
  };
}

export function usePortalEmployee(): PortalEmployee | null {
  // No llegir sessionStorage a l'estat inicial: SSR retorna null i el client podria tenir nom → hydration mismatch.
  const [employee, setEmployee] = useState<PortalEmployee | null>(null);

  useEffect(() => {
    const snap = snapshotToEmployee();
    if (snap) setEmployee(snap);

    let cancelled = false;
    void fetchPortalMe()
      .then((me) => {
        if (!cancelled) setEmployee(me);
      })
      .catch(() => {
        /* keep snapshot if refresh fails */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return employee;
}
