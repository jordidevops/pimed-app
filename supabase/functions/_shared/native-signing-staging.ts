import { log } from "./observability/structured-logger.ts";

const FEATURE = "native-signing-staging";

/** Paths i helpers per al PDF de treball temporal (firma pròpia seqüencial). */

export const DOCUMENTS_BUCKET = "documents";

export function stagingPathForGroup(tenantId: string, groupId: string): string {
  return `${tenantId}/signing-staging/${groupId}/working.pdf`;
}

export async function deleteStagingPdf(
  db: { storage: { from: (b: string) => { remove: (paths: string[]) => Promise<{ error: { message: string } | null }> } } },
  path: string | null | undefined,
): Promise<void> {
  if (!path) return;
  const { error } = await db.storage.from(DOCUMENTS_BUCKET).remove([path]);
  if (error) {
    log("warn", FEATURE, "Failed to delete staging PDF", { extra: { path, error: error.message } });
  }
}
