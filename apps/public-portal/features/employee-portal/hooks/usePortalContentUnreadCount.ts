"use client";

import { useCallback, useEffect, useState } from "react";
import { fetchPortalContent } from "../api/portalApi";
import { usePortalEmployee } from "./usePortalEmployee";
import {
  countPortalContentUnread,
  PORTAL_CONTENT_READ_EVENT,
} from "../utils/portalContentReadState";

export function usePortalContentUnreadCount(moduleEnabled: boolean): number {
  const employee = usePortalEmployee();
  const [count, setCount] = useState(0);

  const refresh = useCallback(async () => {
    if (!moduleEnabled || !employee?.id || !employee.tenant_id) {
      setCount(0);
      return;
    }

    try {
      const data = await fetchPortalContent();
      setCount(countPortalContentUnread(data.items, employee.tenant_id, employee.id));
    } catch {
      setCount(0);
    }
  }, [employee?.id, employee?.tenant_id, moduleEnabled]);

  useEffect(() => {
    void refresh();

    const onUpdate = () => void refresh();
    window.addEventListener(PORTAL_CONTENT_READ_EVENT, onUpdate);
    return () => window.removeEventListener(PORTAL_CONTENT_READ_EVENT, onUpdate);
  }, [refresh]);

  return count;
}
