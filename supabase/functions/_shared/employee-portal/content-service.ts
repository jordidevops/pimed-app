import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalContentListItem {
  id: string;
  slug: string;
  title: string;
  excerpt: string | null;
  content_type: string;
  is_sticky: boolean;
  published_at: string | null;
}

export interface PortalContentListResponse {
  items: PortalContentListItem[];
}

export interface PortalContentDetailResponse {
  id: string;
  slug: string;
  title: string;
  content_type: string;
  content: { html?: string } | null;
  published_at: string | null;
}

export class ContentError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "ContentError";
  }
}

function mapContentRpcError(message: string): ContentError {
  if (message.includes("content_module_disabled")) {
    return new ContentError("content_module_disabled", 403, message);
  }
  if (message.includes("content_not_found") || message.includes("employee_not_found")) {
    return new ContentError("content_not_found", 404, message);
  }
  return new ContentError("content_load_failed", 500, message);
}

export async function listPortalContent(
  employee_id: string,
  tenant_id: string,
  token_id: string,
): Promise<PortalContentListResponse> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_list_content", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    throw mapContentRpcError(error.message);
  }

  const payload = data as { items?: PortalContentListItem[] };

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_content_list",
    http_status: 200,
  }).catch(() => undefined);

  return { items: payload.items ?? [] };
}

export async function getPortalContentBySlug(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  slug: string,
): Promise<PortalContentDetailResponse> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_content_by_slug", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_slug: slug,
  });

  if (error) {
    throw mapContentRpcError(error.message);
  }

  const item = data as PortalContentDetailResponse;

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_content_detail",
    http_status: 200,
    metadata: { slug },
  }).catch(() => undefined);

  return item;
}
