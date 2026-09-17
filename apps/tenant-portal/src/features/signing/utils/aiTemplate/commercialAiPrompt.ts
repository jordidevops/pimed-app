import type { CommercialFullBodyCategory } from '../templateCategories'
import { COMMERCIAL_CONTEXT_FIELDS, commercialRequiredTokens } from '../commercialTemplateContract'

export function commercialFullBodyPromptSection(
  category: CommercialFullBodyCategory,
  templateType: 'html' | 'docx',
): string {
  const kind = category === 'delivery_note' ? 'albarà' : 'pressupost'
  const tokens = commercialRequiredTokens(category, templateType)
  const contextHint = templateType === 'docx'
    ? 'Context (usa aquests camins amb [[camí]], p. ex. [[document.doc_number]]):'
    : 'Context (usa aquests camins al HTML Liquid):'
  const lines: string[] = [
    `IMPORTANT — Aquesta plantilla és el format del mòdul ${kind === 'albarà' ? 'Albarans' : 'Pressupostos'}.`,
    'El motor omple el context niuat següent. NO inventis variables soltes (concepte, import_total, client_signatory, worker).',
    contextHint,
    ...COMMERCIAL_CONTEXT_FIELDS.map((field) => `- ${field}`),
    '',
    'El locale NO ha d\'incloure {{ document_header }} ni {{ document_footer }}: la plantilla és responsable de tot el document.',
    '',
    'Marcadors obligatoris (subcadena exacta, sensible a majúscules). Si en falta cap, el desar falla:',
    ...tokens.map((token) => `- ${token.id}: ${token.example}`),
  ]

  if (templateType === 'html') {
    if (category === 'delivery_note') {
      lines.push('- Signatura: <signature-field role="client_delivery"></signature-field>')
    } else {
      lines.push('- Signatures: <signature-field role="client_accept"></signature-field> i <signature-field role="client_reject"></signature-field>')
    }
    lines.push('- Bucle de línies: {% for line in lines %} … {% endfor %}')
    lines.push('- sample_values del JSON ha de ser niuat (tenant, document, buyer, lines[], totals), no claus planes.')
  } else {
    if (category === 'delivery_note') {
      lines.push('- Signatura: {{Conformitat;role=client_delivery;type=signature}}')
    } else {
      lines.push('- Signatures: {{Accepto;role=client_accept;type=signature}} i {{Refuso;role=client_reject;type=signature}}')
    }
    lines.push('- Bucle de línies: [[#lines]] … [[/lines]]')
    lines.push('- sample_values del JSON ha de ser niuat (tenant, document, buyer, lines[], totals), no claus planes.')
  }

  lines.push(
    category === 'delivery_note'
      ? 'Als "roles" del JSON declara només client_delivery (entity_type contact).'
      : 'Als "roles" del JSON declara només client_accept i client_reject (entity_type contact).',
  )
  lines.push('Deixa "variables" buit o mínim: les dades venen del context, no de camps manuals.')
  return lines.join('\n')
}
