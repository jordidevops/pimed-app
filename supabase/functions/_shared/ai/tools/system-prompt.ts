import type { AiMessage } from "../types.ts";
import type { ProviderToolSchema } from "./types.ts";
import { getMessageTextContent } from "../content-parts.ts";

export function buildToolsSystemAppendix(
  tools: ProviderToolSchema[],
  options?: {
    hasImages?: boolean;
    entityContext?: Record<string, unknown> | null;
    projectLabel?: string;
    priceSheetLabel?: string;
  },
): string {
  if (tools.length === 0) return "";

  const projectLabel = options?.projectLabel?.trim() || "ordre de servei";
  const priceSheetLabel = options?.priceSheetLabel?.trim() || "Full de preus";

  const lines = [
    "EINES DISPONIBLES (function calling — obligatori quan correspongui):",
    "Tens accés a eines del servidor per consultar i proposar canvis a dades del tenant.",
    "NO demanis on estan les dades ni si tens accés: les dades les obtens cridant l'eina adequada.",
    "Exemples:",
    "- Llistar / cercar empleats → crida query_employees",
    "- Activitat / historial / comentaris / tasques d'una entitat → crida query_entity_timeline (necessita entityType + entityId; combina amb query_employees si cal resoldre l'empleat)",
    "- Deixar un resum o nota a la timeline d'una entitat → crida post_entity_timeline_comment (després d'analitzar l'activitat; no per canvis operatius)",
    "- Esdeveniments del calendari del centre → crida query_calendar_events (requereix site actiu)",
    "- Visualitzar dades en gràfic → primer query_* per obtenir dades, després render_chart",
    "- Crear un contacte → crida propose_create_contact",
    "- Extreure contacte d'una imatge adjunta → crida propose_extract_structured_data amb targetType=contact",
    "- Generar document des de plantilla → query_document_templates → query_template_locale → recull variables/rols/acció amb l'usuari → open_document_generator (obre el formulari de l'app; NO propose_generate_document)",
    "- Canviar un empleat → crida propose_update_employee (requereix confirmació de l'usuari)",
    "- Catàleg / PVP → crida query_catalog_items",
    "- Feines anteriors amb línies → crida query_past_jobs",
    `- Consultar la secció «${priceSheetLabel}» d'un/a «${projectLabel}» → crida query_project_price_sheet`,
    "- Plantilles de checklist del tenant → crida query_checklist_templates",
    `- Escriure la secció «${priceSheetLabel}» a un/a «${projectLabel}» → query_catalog_items (i opcionalment query_checklist_templates) → propose_price_sheet. MAI inventis UUIDs; si no hi ha projectId al context, pregunta o no aplicis.`,
  ];

  if (options?.hasImages) {
    lines.push(
      "",
      "EXTRACCIÓ DES D'IMATGES I PDF:",
      "- Si l'usuari adjunta targeta de visita, factura, PDF, captura o document visual i demana extreure dades de contacte,",
      "  analitza el contingut i crida propose_extract_structured_data (targetType=contact).",
      "- Omple només camps visibles a la imatge; marca uncertainFields si algun camp és ambigu.",
      "- Explica a l'usuari què has extret i què cal revisar abans de confirmar.",
    );
  }

  lines.push(
    "",
    "GENERACIÓ DE DOCUMENTS DES DE PLANTILLES:",
    "1. Cerca la plantilla amb query_document_templates.",
    "2. Si duplicateTemplateNames no és buit, pregunta a l'usuari si vol la plantilla HTML o DOCX abans de continuar.",
    "3. Llegeix variables i rols amb query_template_locale (usa requiredVariables i signingRoles de la resposta).",
    "4. Pregunta a l'usuari TOTES les variables obligatòries (p.ex. Acta EPI: data_lliurament, llista_epi) i assigna TOTS els rols necessaris (p.ex. worker = empleat).",
    "5. Obtén dades del context (query_employees, query_entity_timeline, etc.) quan el rol sigui una entitat o cal historial.",
    "6. Pregunta l'acció de sortida amb llenguatge natural. Usa availableOutputActions de query_template_locale (camp label). MAI mostris codis interns (generate_html, generate_docx, etc.) a l'usuari.",
    "7. Només quan no falti cap camp obligatori, crida open_document_generator amb el codi intern corresponent.",
    "8. L'usuari completa el formulari «Generar document»; el resultat apareixerà al xat amb enllaç al document.",
    "9. Per canvis simples (crear contacte, actualitzar empleat) usa propose_* + confirmació.",
    `10. Per omplir la secció «${priceSheetLabel}» d'un/a «${projectLabel}»: query_catalog_items → propose_price_sheet (mode append o replace). Si proposes checklist, ha de ser una plantilla del tenant (query_checklist_templates). L'Acceptar de l'usuari escriu project_lines; no emetis pressupost.`,
    "Els identificadors d'eina (query_project_price_sheet, propose_price_sheet) no canvien encara que la secció tingui un altre nom.",
  );

  const entity = options?.entityContext;
  if (entity && typeof entity === "object") {
    const projectId = typeof entity.projectId === "string" ? entity.projectId : "";
    const tab = typeof entity.tab === "string" ? entity.tab : "";
    if (projectId) {
      lines.push(
        "",
        "CONTEXT DE L'ENTITAT ACTIVA:",
        `- projectId (${projectLabel}): ${projectId}`,
        tab ? `- tab: ${tab}` : "",
        "- Usa aquest projectId a query_project_price_sheet i propose_price_sheet tret que l'usuari en demani un altre.",
      );
    }
  }

  lines.push("", ...tools.map((t) => `- ${t.function.name}: ${t.function.description}`));

  return lines.join("\n");
}

export function appendToolsToMessages(messages: AiMessage[], appendix: string): void {
  if (!appendix.trim()) return;

  const systemIdx = messages.findIndex((m) => m.role === "system");
  if (systemIdx >= 0) {
    const current = messages[systemIdx];
    messages[systemIdx] = {
      ...current,
      content: `${getMessageTextContent(current.content)}\n\n${appendix}`.trim(),
    };
    return;
  }

  messages.unshift({ role: "system", content: appendix });
}
