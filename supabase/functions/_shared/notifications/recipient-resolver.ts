import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { toError } from "./supabase-error.ts";
import type { NotificationSendInput, ResolvedAddress } from "./types.ts";

export async function resolveRecipientAddress(
  adminClient: SupabaseClient,
  input: NotificationSendInput,
): Promise<ResolvedAddress> {
  const recipient = input.recipient;

  if (recipient.kind === "raw_address") {
    return {
      email: recipient.email,
      phoneE164: recipient.phoneE164,
      locale: "ca",
    };
  }

  if (recipient.kind === "tenant_member") {
    const { data, error } = await adminClient
      .from("tenant_members")
      .select("email, full_name")
      .eq("tenant_id", input.tenantId)
      .eq("user_id", recipient.userId)
      .maybeSingle();

    if (error) throw toError(error);

    return {
      email: data?.email ?? undefined,
      displayName: data?.full_name ?? undefined,
      locale: "ca",
    };
  }

  const { data, error } = await adminClient
    .from("contacts")
    .select("email, phone, display_name")
    .eq("id", recipient.contactId)
    .eq("tenant_id", input.tenantId)
    .maybeSingle();

  if (error) throw toError(error);

  return {
    email: data?.email ?? undefined,
    phoneE164: data?.phone ?? undefined,
    displayName: data?.display_name ?? undefined,
    locale: "ca",
  };
}
