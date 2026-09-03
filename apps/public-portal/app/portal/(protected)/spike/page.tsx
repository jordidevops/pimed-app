"use client";

import { useCallback, useEffect, useState } from "react";
import { EMPLOYEE_PORTAL_API_BASE, EMPLOYEE_PORTAL_DEV_SECRETS } from "@/lib/employee-portal/constants";

type EmployeeInfo = {
  id: string;
  tenant_id: string;
  full_name: string;
  pin_required: boolean;
};

export default function EmployeePortalSpikePage() {
  const [employee, setEmployee] = useState<EmployeeInfo | null>(null);
  const [status, setStatus] = useState<string>("Carregant sessió…");
  const [error, setError] = useState<string | null>(null);

  const loadMe = useCallback(async () => {
    setError(null);
    const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/me`, {
      credentials: "include",
      cache: "no-store",
    });

    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setEmployee(null);
      setStatus("Sense sessió");
      setError(body?.error?.code ?? `HTTP ${response.status}`);
      return;
    }

    const body = await response.json();
    setEmployee(body.employee);
    setStatus("Sessió activa");
  }, []);

  useEffect(() => {
    void loadMe();
  }, [loadMe]);

  async function handleRefresh() {
    setStatus("Refrescant…");
    const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/refresh`, {
      method: "POST",
      credentials: "include",
    });
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body?.error?.code ?? `HTTP ${response.status}`);
      setStatus("Refresh fallit");
      return;
    }
    await loadMe();
    setStatus("Sessió refrescada");
  }

  async function handleRevokeDev(tokenId: string) {
    if (process.env.NODE_ENV === "production") return;
    setStatus("Revocant token dev…");
    const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/revoke-dev`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token_id: tokenId, compromised: true }),
    });
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body?.error?.code ?? `HTTP ${response.status}`);
      return;
    }
    setStatus("Token revocat — el següent refresh hauria de fallar");
  }

  return (
    <div className="mx-auto max-w-lg space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">EP0 — Spike sessió</h1>
        <p className="text-muted-foreground mt-1 text-sm">
          Cookie HttpOnly via proxy <code>{EMPLOYEE_PORTAL_API_BASE}/*</code> (mateix domini, sota Path=/portal).
        </p>
      </div>

      <div className="rounded-lg border p-4 text-sm">
        <p>
          <span className="font-medium">Estat:</span> {status}
        </p>
        {employee && (
          <p className="mt-2">
            <span className="font-medium">Empleat:</span> {employee.full_name} (
            {employee.tenant_id.slice(0, 8)}…)
          </p>
        )}
        {error && <p className="text-destructive mt-2">Error: {error}</p>}
      </div>

      <div className="flex flex-wrap gap-2">
        <button
          type="button"
          className="rounded-md bg-primary px-4 py-2 text-primary-foreground text-sm"
          onClick={() => void handleRefresh()}
        >
          Refresh sessió
        </button>
        {process.env.NODE_ENV !== "production" && employee && (
          <button
            type="button"
            className="rounded-md border px-4 py-2 text-sm"
            onClick={() =>
              void handleRevokeDev(
                employee.tenant_id.startsWith("10000000-0000-0000-0000-000000000001")
                  ? "50000000-0000-0000-0000-000000000001"
                  : "50000000-0000-0000-0000-000000000002",
              )
            }
          >
            Simular revocació (dev)
          </button>
        )}
      </div>

      {process.env.NODE_ENV !== "production" && (
        <div className="text-muted-foreground space-y-1 text-xs">
          <p>Secrets dev:</p>
          <p>
            Acme: <code>/e/{EMPLOYEE_PORTAL_DEV_SECRETS.acme}</code>
          </p>
          <p>
            Beta: <code>/e/{EMPLOYEE_PORTAL_DEV_SECRETS.beta}</code>
          </p>
        </div>
      )}
    </div>
  );
}
