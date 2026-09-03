import { createAdminClient } from "../supabase.ts";

import { recordAccessLog } from "./repository.ts";



export interface PortalAbsenceType {

  id: string;

  absence_type: string;

  name_i18n: Record<string, string> | null;

  counts_as_worked: boolean;

  requires_approval: boolean;

  requires_document: boolean;

  max_days_per_year: number | null;

  is_partial: boolean;

  sort_order: number;

}



export interface PortalAbsenceRow {

  id: string;

  absence_type: string;

  start_date: string;

  end_date: string;

  status: string;

  notes: string | null;

  partial_start_time: string | null;

  partial_end_time: string | null;

  created_at: string;

}



export async function getPortalAbsenceTypes(

  employee_id: string,

  tenant_id: string,

): Promise<PortalAbsenceType[]> {

  const db = createAdminClient();



  const { data, error } = await db.rpc("employee_portal_get_absence_types", {

    p_employee_id: employee_id,

    p_tenant_id: tenant_id,

  });



  if (error) {

    throw new AbsenceError("absence_types_failed", 500, error.message);

  }



  return (Array.isArray(data) ? data : []) as PortalAbsenceType[];

}



export async function listPortalAbsences(

  employee_id: string,

  tenant_id: string,

  limit = 50,

): Promise<PortalAbsenceRow[]> {

  const db = createAdminClient();



  const { data, error } = await db.rpc("employee_portal_list_absences", {

    p_employee_id: employee_id,

    p_tenant_id: tenant_id,

    p_limit: limit,

  });



  if (error) {

    throw new AbsenceError("absences_list_failed", 500, error.message);

  }



  return (Array.isArray(data) ? data : []) as PortalAbsenceRow[];

}



export interface RequestPortalAbsenceInput {

  employee_id: string;

  tenant_id: string;

  token_id: string;

  absence_type: string;

  start_date: string;

  end_date: string;

  notes?: string | null;

  partial_start_time?: string | null;

  partial_end_time?: string | null;

}



export async function requestPortalAbsence(

  input: RequestPortalAbsenceInput,

): Promise<{ absence_id: string; status: string }> {

  const db = createAdminClient();



  const { data, error } = await db.rpc("employee_portal_request_absence", {

    p_employee_id: input.employee_id,

    p_tenant_id: input.tenant_id,

    p_absence_type: input.absence_type,

    p_start_date: input.start_date,

    p_end_date: input.end_date,

    p_notes: input.notes ?? null,

    p_partial_start_time: input.partial_start_time ?? null,

    p_partial_end_time: input.partial_end_time ?? null,

  });



  if (error) {

    const message = error.message ?? "request_absence_failed";

    if (message.includes("invalid_absence_type")) {

      throw new AbsenceError("invalid_absence_type", 400, message);

    }

    if (message.includes("absence_overlap")) {

      throw new AbsenceError("absence_overlap", 409, message);

    }

    if (message.includes("invalid_date_range")) {

      throw new AbsenceError("invalid_date_range", 400, message);

    }

    throw new AbsenceError("request_absence_failed", 500, message);

  }



  const result = data as { absence_id: string; status: string };



  await recordAccessLog({

    token_id: input.token_id,

    employee_id: input.employee_id,

    tenant_id: input.tenant_id,

    action: "request_absence",

    http_status: 200,

  }).catch(() => undefined);



  return result;

}



export class AbsenceError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "AbsenceError";
  }
}

