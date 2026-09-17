import { ENTITY_FIELD_CATALOG } from '../../constants/entityFieldCatalog'
import type { LocaleKeySnapshot } from './validation'
import type { TenantRoleDefault } from '../../api/useTenantRoleDefaults'
import {
  resolvePromptRoles,
  rolesForPathVariables,
  exampleRoleKeys,
} from './promptRoleContext'
import type { AiPromptUserConfig } from './promptUserConfig'
import { ROLE_CATALOG_BY_KEY } from '../../constants/roleCatalog'
import { isFullBodyTemplateCategory } from '../templateCategories'
import { commercialFullBodyPromptSection } from './commercialAiPrompt'

export interface PromptGeneratorOptions {
  targetLocale: string
  templateType: 'html' | 'docx'
  useCaseHint?: string
  siblingLocales?: LocaleKeySnapshot[]
  contentBlocksActive?: boolean
  tenantRoleDefaults?: TenantRoleDefault[]
  siteId?: string | null
  userConfig?: AiPromptUserConfig
  category?: string | null
}

function buildJsonSchemaExample(
  templateType: 'html' | 'docx',
  targetLocale: string,
  roleKeys: [string, string],
  roleLabels: [string, string],
  emptyVariables = false,
): string {
  const [roleA, roleB] = roleKeys
  const [labelA, labelB] = roleLabels
  const sameRole = roleA === roleB
  const rolesJson = sameRole
    ? `[
    { "key": "${roleA}", "label": "${labelA}", "entity_type": "contact", "for_signing": true }
  ]`
    : `[
    { "key": "${roleA}", "label": "${labelA}", "entity_type": "${emptyVariables ? 'contact' : 'employee'}", "for_signing": true },
    { "key": "${roleB}", "label": "${labelB}", "entity_type": "${emptyVariables ? 'contact' : 'employee'}", "for_signing": true }
  ]`
  const variablesJson = emptyVariables
    ? '[]'
    : `[
    { "key": "salari_brut", "label": "Salari brut anual", "type": "number", "required": true },
    { "key": "data_inici", "label": "Data d'inici", "type": "date", "required": true }
  ]`

  if (templateType === 'docx') {
    return `{
  "locale": "${targetLocale}",
  "format": "docx",
  "roles": ${rolesJson},
  "variables": ${variablesJson}
}`
  }

  return `{
  "locale": "${targetLocale}",
  "format": "html",
  "roles": ${rolesJson},
  "variables": ${variablesJson},
  "content": "<div>...</div>"
}`
}

function formatRoleLine(role: { key: string; entity_type: string; for_signing: boolean; label: string; defaultEntityLabel?: string | null }): string {
  let line = `- ${role.key} (${role.entity_type}, signa: ${role.for_signing ? 'sí' : 'no'}, label: "${role.label}")`
  if (role.defaultEntityLabel) {
    line += ` — default organització: ${role.defaultEntityLabel}`
  }
  return line
}

export function buildAiTemplatePrompt(opts: PromptGeneratorOptions): string {
  const lines: string[] = []
  const commercial = isFullBodyTemplateCategory(opts.category)
  const defaultUseCase = commercial
    ? (opts.category === 'delivery_note'
      ? 'Albarà de lliurament (format del mòdul Albarans)'
      : 'Pressupost comercial (format del mòdul Pressupostos)')
    : '[DESCRIPCIÓ DEL DOCUMENT, ex: Acord de confidencialitat (NDA) per a empleats]'
  const useCase = opts.useCaseHint?.trim() || defaultUseCase
  const resolvedRoles = resolvePromptRoles(opts.tenantRoleDefaults ?? [], opts.siteId, opts.targetLocale)
  const [exampleA, exampleB] = exampleRoleKeys(resolvedRoles)
  const exampleLabels: [string, string] = [
    resolvedRoles.configured.find(r => r.key === exampleA)?.label
      ?? resolvedRoles.contextAuto.find(r => r.key === exampleA)?.label
      ?? 'Treballador/a',
    resolvedRoles.configured.find(r => r.key === exampleB)?.label
      ?? resolvedRoles.contextAuto.find(r => r.key === exampleB)?.label
      ?? 'Responsable',
  ]
  const contentBlocksActive = !!opts.contentBlocksActive && !commercial

  lines.push(`Actua com un expert legal i enginyer de programari. Necessito que creïs el contingut per a una plantilla de ${useCase}, en l'idioma "${opts.targetLocale}".`)
  lines.push(`El format de sortida és ${opts.templateType.toUpperCase()} (ja determinat per la plantilla que s'està editant).`)
  lines.push('')

  const cfg = opts.userConfig
  if (cfg) {
    lines.push('IMPORTANT — Requisits del document (configuració de l\'usuari):')
    if (cfg.internalDocumentOnly) {
      lines.push('- Document INTERNE: sense camps de signatura ni rols amb for_signing: true.')
    } else {
      const signerHint = {
        none: 'Cap signatura requerida (tots els rols amb for_signing: false o sense rols signants).',
        one: 'Exactament 1 signant.',
        two: '2 signants (p. ex. treballador + responsable, o client + tècnic).',
        three_plus: '3 o més signants; declara cada rol amb for_signing: true.',
      }[cfg.signerCount]
      lines.push(`- Signants: ${signerHint}`)
      if (cfg.includeSignatureFields && opts.templateType === 'html') {
        lines.push('- Inclou <signature-field role="CLAU_ROL"> per a cada rol que signi.')
        lines.push('- Opcional: <date-field role="CLAU_ROL"> per a data de signatura.')
      }
      if (cfg.includeSignatureFields && opts.templateType === 'docx') {
        lines.push('- Al Word (referència per l\'usuari): {{Firma;role=CLAU_ROL;type=signature}} per a cada signant.')
      }
    }
    if (cfg.roleKeys.length > 0 && !commercial) {
      const roleDesc = cfg.roleKeys.map(key => {
        const cat = ROLE_CATALOG_BY_KEY[key]
        return cat ? `${key} (${cat.entity_type})` : key
      }).join(', ')
      lines.push(`- Rols que el document HA d'incloure al JSON "roles": ${roleDesc}`)
      lines.push('- Usa exactament aquestes "key" (snake_case anglès); tradueix només els "label" a l\'idioma del locale.')
    }
    if (cfg.preferPathBasedIdentity && !commercial) {
      lines.push('- Per a nom, DNI/NIE i càrrec: usa path-based ({{ worker.full_name }}, {{ worker.document_id }}) sense posar-les a "variables".')
      lines.push('- Reserva "variables" per a dates, imports i textos que l\'usuari ompli manualment.')
    }
    if (cfg.notes?.trim()) {
      lines.push(`- Notes addicionals: ${cfg.notes.trim()}`)
    }
    lines.push('')
  }

  lines.push('Genera el resultat exclusivament en format JSON vàlid (sense markdown ni text addicional).')

  if (opts.templateType === 'html') {
    lines.push('')
    lines.push('IMPORTANT — Format: HTML amb variables LiquidJS (`{{ variable }}` o `{{ rol.camp }}`).')
    lines.push('IMPORTANT — Camps de signatura: usa elements `<signature-field role="ROL" ...></signature-field>` per als rols que signen.')
  } else {
    lines.push('')
    lines.push('IMPORTANT — Format DOCX: NO generis "content" HTML. Només retorna "roles" i "variables".')
    lines.push('Les variables al Word s\'han d\'etiquetar com [[clau]] i els camps de signatura com {{Camp;role=Rol;type=signature}}.')
  }

  if (commercial && isFullBodyTemplateCategory(opts.category)) {
    lines.push('')
    lines.push(commercialFullBodyPromptSection(opts.category, opts.templateType))
  } else {
    lines.push('')
    lines.push('IMPORTANT — Context automàtic (usa directament al HTML, NO el posis a "roles" ni "variables"):')
    lines.push('- Empresa actual: {{ tenant.name }}, {{ tenant.tax_id }}, {{ tenant.address }}, {{ tenant.logo_url }}, {{ tenant.email }}, etc.')
    lines.push('- Seu activa (si aplica): {{ site.name }}, {{ site.address }}, {{ site.phone }}, etc.')
    lines.push('- Dates/globals: {{ globals.date }}, {{ globals.today }}, {{ globals.year }}, {{ globals.now }} (també {{ today }}, {{ year }}, {{ now }})')
    if (contentBlocksActive) {
      lines.push('- Blocs de document: {{ document_header }}, {{ document_footer }} (injectats per separat, no al body)')
    }

    if (resolvedRoles.configured.length > 0) {
      lines.push('')
      lines.push('IMPORTANT — Rols preferits per aquesta organització (configurats a /settings/templates). Prioritza aquestes keys:')
      for (const role of resolvedRoles.configured) {
        lines.push(formatRoleLine(role))
      }
    }

    if (resolvedRoles.contextAuto.length > 0) {
      lines.push('')
      lines.push('IMPORTANT — Rols que normalment es resolen del context del document (no cal assignació per defecte):')
      for (const role of resolvedRoles.contextAuto) {
        lines.push(`- ${role.key} (${role.entity_type}, signa: ${role.for_signing ? 'sí' : 'no'})`)
      }
    }

    lines.push('')
    lines.push('IMPORTANT — Altres rols disponibles del catàleg (declara\'ls a "roles" només si el document ho requereix):')
    for (const role of resolvedRoles.catalogRest) {
      lines.push(`- ${role.key} (${role.entity_type}, signa: ${role.for_signing ? 'sí' : 'no'})`)
    }

    lines.push('')
    lines.push('IMPORTANT — Variables path-based per rol declarat (ex: si declares el rol "worker", pots usar):')
    for (const role of rolesForPathVariables(resolvedRoles)) {
      const fields = ENTITY_FIELD_CATALOG[role.entity_type]
      if (!fields) continue
      const vars = fields.map(f => `{{ ${role.key}.${f.field} }}`).join(', ')
      lines.push(`- rol "${role.key}" (${role.entity_type}): ${vars}`)
    }

    lines.push('')
    lines.push('IMPORTANT — Variables manuals (declara-les a "variables" del JSON):')
    lines.push('- Claus simples sense punt: {{ salari_brut }}, {{ data_inici }}, etc.')
    lines.push('')
    lines.push('NO confonguis tenant/site/globals amb rols de document. tenant.* i site.* es resolen sols.')
  }

  const sibling = opts.siblingLocales?.find(s => s.locale !== opts.targetLocale)
  if (sibling) {
    lines.push('')
    lines.push(`IMPORTANT — Aquesta plantilla ja té el locale "${sibling.locale}". Reutilitza exactament aquestes keys:`)
    lines.push(`- Rols: ${sibling.roleKeys.join(', ') || '(cap)'}`)
    lines.push(`- Variables: ${sibling.variableKeys.join(', ') || '(cap)'}`)
    lines.push(`Només tradueix els "label" i el "content" a "${opts.targetLocale}".`)
  }

  if (contentBlocksActive) {
    lines.push('')
    lines.push('IMPORTANT — No incloguis capçaleres ni peus de pàgina al "content"; es gestionen per separat mitjançant blocs reutilitzables (DOCUMENT_HEADER, DOCUMENT_FOOTER).')
  }

  if (opts.templateType === 'html' && !commercial) {
    lines.push('')
    lines.push('IMPORTANT — Dates al HTML: formata variables type "date" amb Liquid: {{ data_camp | date: "%d/%m/%Y" }}.')
  }

  lines.push('')
  lines.push('Esquema JSON esperat (un sol locale):')
  if (commercial && isFullBodyTemplateCategory(opts.category)) {
    const acceptRole = opts.category === 'delivery_note' ? 'client_delivery' : 'client_accept'
    const acceptLabel = opts.category === 'delivery_note' ? 'Conformitat de lliurament' : 'Accepto'
    if (opts.category === 'quote') {
      lines.push(buildJsonSchemaExample(
        opts.templateType,
        opts.targetLocale,
        ['client_accept', 'client_reject'],
        [acceptLabel, 'Refuso'],
        true,
      ))
    } else {
      lines.push(buildJsonSchemaExample(
        opts.templateType,
        opts.targetLocale,
        [acceptRole, acceptRole],
        [acceptLabel, acceptLabel],
        true,
      ))
    }
  } else {
    lines.push(buildJsonSchemaExample(opts.templateType, opts.targetLocale, [exampleA, exampleB], exampleLabels))
  }

  return lines.join('\n')
}
