const PIN_REQUIRED_KEY = "employee_portal_pin_required";
const EMPLOYEE_SNAPSHOT_KEY = "employee_portal_employee";

export interface PortalEmployeeSnapshot {
  id: string;
  tenant_id: string;
  full_name: string;
  pin_required: boolean;
  work_profile?: string;
  legacy_in_out_only?: boolean;
}

export function persistPortalSessionFlags(employee: PortalEmployeeSnapshot): void {
  if (typeof sessionStorage === "undefined") return;
  sessionStorage.setItem(PIN_REQUIRED_KEY, employee.pin_required ? "1" : "0");
  sessionStorage.setItem(EMPLOYEE_SNAPSHOT_KEY, JSON.stringify(employee));
}

export function readPortalEmployeeSnapshot(): PortalEmployeeSnapshot | null {
  if (typeof sessionStorage === "undefined") return null;
  try {
    const raw = sessionStorage.getItem(EMPLOYEE_SNAPSHOT_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as PortalEmployeeSnapshot;
  } catch {
    return null;
  }
}

export function readPortalPinRequired(): boolean {
  if (typeof sessionStorage === "undefined") return false;
  return sessionStorage.getItem(PIN_REQUIRED_KEY) === "1";
}

export function clearPortalSessionFlags(): void {
  if (typeof sessionStorage === "undefined") return;
  sessionStorage.removeItem(PIN_REQUIRED_KEY);
  sessionStorage.removeItem(EMPLOYEE_SNAPSHOT_KEY);
}
