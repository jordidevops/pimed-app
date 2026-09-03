/**
 * Construeix el WorkflowContext inicial per a un workflow que acaba de ser trigerat.
 */

import type { AdminClient } from "../queue-runtime.ts";
import type { WorkflowContext } from "./types.ts";
import { log } from "../observability/structured-logger.ts";

const FEATURE = "context-builder";

interface TenantBasic {
  id: string;
  name: string;
  slug?: string;
}

interface SiteBasic {
  id: string;
  name: string;
}

export async function buildWorkflowContext(
  db: AdminClient,
  params: {
    tenantId: string;
    siteId: string | null;
    eventType: string;
    entityType: string | null;
    entityId: string | null;
    actorUserId: string | null;
    payload: Record<string, unknown>;
  },
): Promise<WorkflowContext> {
  const { data: tenantData, error: tenantError } = await db.rpc(
    "get_tenant_basic",
    { p_tenant_id: params.tenantId },
  );

  if (tenantError || !tenantData) {
    log("warn", FEATURE, "Could not fetch tenant basic data — using fallback", {
      tenantId: params.tenantId,
      extra: { error: tenantError?.message ?? "no data" },
    });
  }

  const tenant: WorkflowContext["tenant"] = tenantData
    ? {
      id: (tenantData as TenantBasic).id ?? params.tenantId,
      name: (tenantData as TenantBasic).name ?? "",
      slug: (tenantData as TenantBasic).slug,
    }
    : { id: params.tenantId, name: "" };

  let site: WorkflowContext["site"] = null;
  if (params.siteId) {
    const { data: siteData, error: siteError } = await db.rpc("get_site_basic", {
      p_site_id: params.siteId,
    });

    if (siteError) {
      log("warn", FEATURE, "Could not fetch site basic data", {
        tenantId: params.tenantId,
        extra: { siteId: params.siteId, error: siteError.message },
      });
    } else if (siteData) {
      site = {
        id: (siteData as SiteBasic).id,
        name: (siteData as SiteBasic).name,
      };
    }
  }

  let entity: Record<string, unknown> | undefined;

  if (params.entityId && params.entityType) {
    const { data: snapshot, error: snapError } = await db.rpc(
      "get_entity_snapshot_for_automation",
      {
        p_tenant_id: params.tenantId,
        p_entity_type: params.entityType,
        p_entity_id: params.entityId,
      },
    );

    if (snapError) {
      log("warn", FEATURE, "Entity snapshot failed — using payload", {
        tenantId: params.tenantId,
        extra: { error: snapError.message },
      });
      entity = params.payload;
    } else {
      const snap = (snapshot ?? {}) as Record<string, unknown>;
      entity = Object.keys(snap).length > 0
        ? { ...params.payload, ...snap }
        : params.payload;
    }
  } else if (params.entityId) {
    entity = params.payload;
  }

  let document: Record<string, unknown> | undefined;
  if (params.eventType === "DOCUMENT_GENERATED" || params.entityType === "document") {
    const docId = (params.payload.document_id as string) ?? params.entityId;
    if (docId) {
      const { data: docSnap } = await db.rpc("get_entity_snapshot_for_automation", {
        p_tenant_id: params.tenantId,
        p_entity_type: "document",
        p_entity_id: docId,
      });
      document = {
        ...(docSnap as Record<string, unknown> ?? {}),
        storage_path: params.payload.storage_path,
        version_id: params.payload.version_id,
      };
    }
  }

  const roles: Record<string, Record<string, unknown>> = {};
  if (entity?.email) {
    roles.worker = {
      email: entity.email,
      name: entity.full_name ?? entity.display_name ?? entity.name,
    };
  }
  if (entity?.owner_user_id) {
    roles.manager = { user_id: entity.owner_user_id };
  }

  const context: WorkflowContext = {
    trigger: {
      event: params.eventType,
      entity_type: params.entityType,
      entity_id: params.entityId,
      actor_user_id: params.actorUserId,
      site_id: params.siteId,
      timestamp: new Date().toISOString(),
      payload: params.payload,
    },
    tenant,
    site,
    entity,
    document,
    roles,
    variables: (params.payload.variables as Record<string, unknown>) ?? {},
    steps: {},
  };

  return context;
}
