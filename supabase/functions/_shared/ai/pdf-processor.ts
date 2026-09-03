import { extractText, getDocumentProxy } from "unpdf";
import type { AiProvider } from "./types.ts";
import { bytesToBase64 } from "./chat-attachments.ts";
import { log } from "../observability/structured-logger.ts";

const FEATURE = "pdf-processor";

const MIN_TEXT_CHARS = 40;
const MAX_EXTRACT_CHARS = 12_000;

export type ProcessedPdfPart =
  | { type: "text"; text: string }
  | { type: "file"; mimeType: string; base64: string };

export async function extractPdfFirstPageText(pdfBytes: Uint8Array): Promise<string> {
  try {
    const pdf = await getDocumentProxy(pdfBytes);
    const { text } = await extractText(pdf, { mergePages: false });
    if (Array.isArray(text) && text.length > 0) {
      return (text[0] ?? "").trim();
    }
    if (typeof text === "string") return text.trim();
    return "";
  } catch (err) {
    log("warn", FEATURE, "extractText failed", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    return "";
  }
}

/** REC-8: all pages merged (digital PDF text layer). Empty → scanned / image-only. */
export async function extractPdfAllText(pdfBytes: Uint8Array): Promise<string> {
  try {
    const pdf = await getDocumentProxy(pdfBytes);
    const { text } = await extractText(pdf, { mergePages: true });
    if (typeof text === "string") return text.trim();
    if (Array.isArray(text)) {
      return text.map((p) => (typeof p === "string" ? p : "")).join("\n\n").trim();
    }
    return "";
  } catch (err) {
    log("warn", FEATURE, "extractPdfAllText failed", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    return "";
  }
}

export async function processPdfForProvider(
  pdfBytes: Uint8Array,
  fileName: string,
  provider: AiProvider,
): Promise<ProcessedPdfPart[]> {
  const firstPageText = await extractPdfFirstPageText(pdfBytes);
  const label = fileName.trim() || "document.pdf";
  const parts: ProcessedPdfPart[] = [];

  if (provider === "gemini") {
    if (firstPageText.length > 0) {
      parts.push({
        type: "text",
        text: `[Extracte text pàgina 1 del PDF «${label}»]\n${firstPageText.slice(0, MAX_EXTRACT_CHARS)}`,
      });
    }
    parts.push({
      type: "file",
      mimeType: "application/pdf",
      base64: bytesToBase64(pdfBytes),
    });
    return parts;
  }

  if (firstPageText.length >= MIN_TEXT_CHARS) {
    parts.push({
      type: "text",
      text: `[Contingut extret del PDF «${label}» (pàgina 1)]\n\n${firstPageText.slice(0, MAX_EXTRACT_CHARS)}`,
    });
    return parts;
  }

  throw new Error(
    "No s'ha pogut extreure text del PDF (probablement escanejat). "
      + "Utilitza un model Gemini o adjunta una captura d'imatge del document.",
  );
}
