"use client";

import { useEffect } from "react";
import { refreshPortalSession } from "../api/portalApi";

const REFRESH_INTERVAL_MS = 11 * 60 * 1000;

/** Renova la cookie de sessió abans dels 15 min d'expiració JWT. */
export function PortalSessionRefresh() {
  useEffect(() => {
    const tick = () => {
      void refreshPortalSession().catch(() => undefined);
    };

    const id = window.setInterval(tick, REFRESH_INTERVAL_MS);
    return () => window.clearInterval(id);
  }, []);

  return null;
}
