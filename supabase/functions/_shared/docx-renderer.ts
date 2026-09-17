/**
 * docx-renderer.ts — Motor de renderitzat de documents DOCX amb Docxtemplater
 *
 * Sintaxi de plantilles DOCX:
 *   - Variables simples: [[ variable ]]
 *   - Loops:             [[#items]] ... [[/items]]
 *
 * Tags de signatura DocuSeal: {{Field;role=Role;type=signature}}
 *   → Usen {{ }} i NO col·lideixen amb els delimitadors [[ ]]
 *   → Docxtemplater els ignora; DocuSeal els interpreta com a camps interactius.
 *
 * Límit de mida: rebutja fitxers > 20 MB (protecció memòria Edge Function 128 MB).
 */

import PizZip          from "npm:pizzip@3";
import Docxtemplater   from "npm:docxtemplater@3";

const MAX_DOCX_BYTES = 20 * 1024 * 1024; // 20 MB

/**
 * Default Docxtemplater parser does not split dotted tags (`document.doc_number`
 * looks up the `document` object and prints nothing). QT-6 probe:
 * `scripts/docx-nested-paths-probe.mjs`. Flat keys (`full_name`) still work.
 */
export function dottedPathParser(tag: string): {
  get: (scope: unknown) => unknown;
} {
  const keys = tag === "." ? [] : String(tag).split(".");
  return {
    get(scope: unknown) {
      if (tag === ".") return scope;
      let current: unknown = scope;
      for (const key of keys) {
        if (current == null || typeof current !== "object") return undefined;
        current = (current as Record<string, unknown>)[key];
      }
      return current;
    },
  };
}

/**
 * Renderitza un fitxer DOCX (Uint8Array) substituint les variables [[key]]
 * amb els valors del context. Retorna el DOCX renderitzat com a Uint8Array.
 *
 * @throws Error si el fitxer és massa gran, no és un ZIP vàlid, o la plantilla
 *         conté errors de sintaxi de Docxtemplater.
 */
export function renderDocx(
  input: Uint8Array,
  context: Record<string, unknown>,
): Uint8Array {
  if (input.byteLength > MAX_DOCX_BYTES) {
    throw new Error(
      `docx_too_large: El fitxer DOCX supera el límit de 20 MB ` +
      `(${Math.round(input.byteLength / 1024 / 1024)} MB)`,
    );
  }

  let zip: InstanceType<typeof PizZip>;
  try {
    zip = new PizZip(input);
  } catch (err) {
    throw new Error(
      `docx_parse_error: No s'ha pogut llegir el fitxer DOCX: ${(err as Error).message}`,
    );
  }

  const doc = new Docxtemplater(zip, {
    delimiters:    { start: "[[", end: "]]" },
    paragraphLoop: true,
    linebreaks:    true,
    parser:        dottedPathParser,
    // Si el valor no existeix, no escrivim "undefined" al document final.
    // Mantenim el placeholder original per facilitar debugging i retrocompatibilitat.
    nullGetter: (part: { raw?: string } | undefined) => {
      const raw = part?.raw?.trim();
      return raw ? `[[${raw}]]` : "";
    },
  });

  try {
    doc.render(context);
  } catch (err) {
    // Docxtemplater llança errors amb .properties.errors per a errors de plantilla
    const dtErr = err as {
      properties?: { errors?: Array<{ message: string }> };
      message?: string;
    };
    if (dtErr.properties?.errors?.length) {
      const details = dtErr.properties.errors.map((e) => e.message).join("; ");
      throw new Error(`docx_template_error: ${details}`);
    }
    throw new Error(`docx_render_error: ${dtErr.message ?? String(err)}`);
  }

  return doc.getZip().generate({ type: "uint8array" });
}
