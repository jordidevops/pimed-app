import { Liquid } from 'liquidjs'
import { getLiquidTemplateSyntaxError } from '@/lib/liquidTemplateValidation'
import type { SigningRolesSchema, VariablesSchema } from '../../api/signingService'
import { aiRolesToSchema, aiVariablesToSchema, keysMatchSet, schemaToKeySets } from './mappers'
import { unwrapAiImportPayload, type AILocalePayload } from './schema'
import { extractLiquidReferences, isGlobalLiquidRef, isPathBasedRef } from './extractLiquidRefs'
import { generateDummyPreviewValues } from './dummyData'

const dryEngine = new Liquid({ strictVariables: false, strictFilters: false })

export interface LocaleKeySnapshot {
  locale: string
  variableKeys: string[]
  roleKeys: string[]
}

export interface AiValidationIssue {
  level: 'error' | 'warning'
  code: string
  message: string
}

export interface AiValidationResult {
  ok: boolean
  payload?: AILocalePayload
  variablesSchema: VariablesSchema | null
  rolesSchema: SigningRolesSchema
  issues: AiValidationIssue[]
}

function declaredVariableKeys(payload: AILocalePayload): Set<string> {
  return new Set(payload.variables.map(v => v.key))
}

function declaredRoleKeys(payload: AILocalePayload): Set<string> {
  return new Set(payload.roles.map(r => r.key))
}

export function validateAiLocaleImport(
  rawJson: string,
  opts: {
    targetLocale: string
    templateType: 'html' | 'docx'
    siblingLocales?: LocaleKeySnapshot[]
    contentBlocksActive?: boolean
  },
): AiValidationResult {
  const issues: AiValidationIssue[] = []

  let payload: AILocalePayload
  try {
    const parsed = JSON.parse(rawJson)
    payload = unwrapAiImportPayload(parsed)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (msg === 'MULTIPLE_LOCALES') {
      return {
        ok: false,
        variablesSchema: null,
        rolesSchema: {},
        issues: [{ level: 'error', code: 'multiple_locales', message: 'El JSON conté més d\'un locale. Enganxa només el locale que estàs editant.' }],
      }
    }
    return {
      ok: false,
      variablesSchema: null,
      rolesSchema: {},
      issues: [{ level: 'error', code: 'invalid_json', message: `JSON invàlid: ${msg}` }],
    }
  }

  if (opts.templateType === 'html') {
    if (!payload.content?.trim()) {
      issues.push({ level: 'error', code: 'missing_content', message: 'Falta el camp "content" amb el HTML de la plantilla.' })
    }
  }

  const rolesSchema = aiRolesToSchema(payload.roles)
  const variablesSchema = aiVariablesToSchema(payload.variables)

  if (opts.templateType === 'docx' && payload.content?.trim()) {
    issues.push({
      level: 'error',
      code: 'docx_content_not_allowed',
      message: 'En mode DOCX no s\'inclou "content" HTML. Només retorna "roles" i "variables".',
    })
  }

  if (opts.templateType === 'html' && payload.content?.trim()) {
    const syntaxErr = getLiquidTemplateSyntaxError(payload.content)
    if (syntaxErr) {
      issues.push({ level: 'error', code: 'liquid_syntax', message: `Error de sintaxi Liquid: ${syntaxErr}` })
    } else {
      try {
        const dummy = generateDummyPreviewValues(variablesSchema, rolesSchema)
        dryEngine.parseAndRenderSync(payload.content, dummy)
      } catch (err) {
        issues.push({
          level: 'error',
          code: 'liquid_render',
          message: `Error en renderitzar la plantilla: ${err instanceof Error ? err.message : String(err)}`,
        })
      }
    }

    const refs = extractLiquidReferences(payload.content)
    const varKeys = declaredVariableKeys(payload)
    const roleKeys = declaredRoleKeys(payload)

    for (const ref of refs) {
      if (isGlobalLiquidRef(ref)) continue
      if (isPathBasedRef(ref)) {
        const [roleKey] = ref.split('.')
        if (!roleKeys.has(roleKey)) {
          issues.push({
            level: 'error',
            code: 'undeclared_path_role',
            message: `Variable "${ref}" fa referència al rol "${roleKey}" que no està declarat a "roles".`,
          })
        }
        continue
      }
      if (!varKeys.has(ref)) {
        issues.push({
          level: 'error',
          code: 'undeclared_variable',
          message: `Variable "${ref}" usada al contingut però no declarada a "variables".`,
        })
      }
    }

    for (const key of varKeys) {
      if (!refs.includes(key)) {
        issues.push({
          level: 'warning',
          code: 'unused_variable',
          message: `Variable "${key}" declarada però no usada al contingut.`,
        })
      }
    }
  }

  for (const sibling of opts.siblingLocales ?? []) {
    if (sibling.locale === opts.targetLocale) continue
    const importedVarKeys = payload.variables.map(v => v.key)
    const importedRoleKeys = payload.roles.map(r => r.key)
    if (!keysMatchSet(importedVarKeys, sibling.variableKeys)) {
      issues.push({
        level: 'warning',
        code: 'locale_var_mismatch',
        message: `Les variables d'aquest idioma no coincideixen amb les del locale "${sibling.locale}". Considera usar "Copiar des de ${sibling.locale}" i traduir.`,
      })
    }
    if (!keysMatchSet(importedRoleKeys, sibling.roleKeys)) {
      issues.push({
        level: 'warning',
        code: 'locale_role_mismatch',
        message: `Els rols d'aquest idioma no coincideixen amb els del locale "${sibling.locale}".`,
      })
    }
  }

  const hasErrors = issues.some(i => i.level === 'error')
  return {
    ok: !hasErrors,
    payload,
    variablesSchema,
    rolesSchema,
    issues,
  }
}

export function localeToKeySnapshot(
  locale: string,
  variablesSchema: unknown,
  rolesSchema: unknown,
): LocaleKeySnapshot {
  const { variableKeys, roleKeys } = schemaToKeySets(variablesSchema, rolesSchema)
  return { locale, variableKeys, roleKeys }
}
