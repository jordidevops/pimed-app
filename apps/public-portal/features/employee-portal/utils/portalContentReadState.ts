import type { PortalContentListItem } from "../api/portalApi";

const STORAGE_PREFIX = "employee_portal_content_read";

export const PORTAL_CONTENT_READ_EVENT = "portal-content-read-updated";

function storageKey(tenantId: string, employeeId: string): string {
  return `${STORAGE_PREFIX}:${tenantId}:${employeeId}`;
}

/** slug → published_at ISO quan es va marcar com a llegit */
type ReadState = Record<string, string>;

function readState(tenantId: string, employeeId: string): ReadState {
  if (typeof localStorage === "undefined") return {};
  try {
    const raw = localStorage.getItem(storageKey(tenantId, employeeId));
    if (!raw) return {};
    return JSON.parse(raw) as ReadState;
  } catch {
    return {};
  }
}

function writeState(tenantId: string, employeeId: string, state: ReadState): void {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(storageKey(tenantId, employeeId), JSON.stringify(state));
}

export function notifyPortalContentReadUpdated(): void {
  if (typeof window === "undefined") return;
  window.dispatchEvent(new CustomEvent(PORTAL_CONTENT_READ_EVENT));
}

export function isPortalContentUnread(
  item: Pick<PortalContentListItem, "slug" | "published_at">,
  tenantId: string,
  employeeId: string,
): boolean {
  const state = readState(tenantId, employeeId);
  const readAt = state[item.slug];
  if (!readAt) return true;
  if (!item.published_at) return false;
  return item.published_at > readAt;
}

export function countPortalContentUnread(
  items: PortalContentListItem[],
  tenantId: string,
  employeeId: string,
): number {
  return items.filter((item) => isPortalContentUnread(item, tenantId, employeeId)).length;
}

export function markPortalContentSlugRead(
  tenantId: string,
  employeeId: string,
  slug: string,
  publishedAt: string | null,
): void {
  const state = readState(tenantId, employeeId);
  state[slug] = publishedAt ?? new Date().toISOString();
  writeState(tenantId, employeeId, state);
  notifyPortalContentReadUpdated();
}

export function markAllPortalContentRead(
  items: PortalContentListItem[],
  tenantId: string,
  employeeId: string,
): void {
  const state = readState(tenantId, employeeId);
  for (const item of items) {
    state[item.slug] = item.published_at ?? new Date().toISOString();
  }
  writeState(tenantId, employeeId, state);
  notifyPortalContentReadUpdated();
}
