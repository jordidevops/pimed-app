import type { z } from "zod";
import { ContactExtractFields } from "../schemas/domains/contact.ts";

type ContactFields = z.infer<typeof ContactExtractFields>;

export function buildContactProposalPayload(
  contact: ContactFields,
  extras?: Record<string, unknown>,
): {
  payload: Record<string, unknown>;
  preview: Record<string, unknown>;
} {
  const preview = {
    kind: contact.kind,
    displayName: contact.displayName,
    email: contact.email || null,
    phone: contact.phone || null,
    taxId: contact.taxId || null,
    givenName: contact.givenName || null,
    familyName: contact.familyName || null,
    legalName: contact.legalName || null,
    ...extras,
  };

  const payload = {
    kind: contact.kind,
    displayName: contact.displayName,
    givenName: contact.givenName ?? null,
    familyName: contact.familyName ?? null,
    legalName: contact.legalName ?? null,
    taxId: contact.taxId ?? null,
    email: contact.email && contact.email !== "" ? contact.email : null,
    phone: contact.phone ?? null,
    phoneAlt: contact.phoneAlt ?? null,
    preferredChannel: contact.preferredChannel ?? "email",
    tags: contact.tags ?? [],
    preview,
  };

  return { payload, preview };
}

export function buildExtractContactProposalPayload(
  contact: ContactFields,
  meta: {
    confidence?: "high" | "medium" | "low";
    sourceHint?: string;
    uncertainFields?: string[];
  },
): {
  payload: Record<string, unknown>;
  preview: Record<string, unknown>;
} {
  const { preview: contactPreview, payload: contactPayload } = buildContactProposalPayload(contact);
  const preview = {
    ...contactPreview,
    targetType: "contact",
    confidence: meta.confidence ?? null,
    sourceHint: meta.sourceHint ?? null,
    uncertainFields: meta.uncertainFields ?? [],
  };

  return {
    payload: {
      targetType: "contact",
      contact: contactPayload,
      confidence: meta.confidence ?? null,
      sourceHint: meta.sourceHint ?? null,
      uncertainFields: meta.uncertainFields ?? [],
      preview,
    },
    preview,
  };
}
