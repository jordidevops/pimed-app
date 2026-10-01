import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import type { DocumentTemplateWithLocales } from '@/features/signing/api/signingService'
import {
  FORMALIZATION_MODES,
  type FormalizationMode,
} from '../utils/deviationApprovalThreshold'
import { QUOTE_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import { DocumentTemplateSelect } from './AgreementTemplateSelect'

interface QuoteFormalizationFieldsProps {
  mode: FormalizationMode
  templateId: string
  templates: DocumentTemplateWithLocales[]
  disabled?: boolean
  onModeChange: (mode: FormalizationMode) => void
  onTemplateChange: (templateId: string) => void
}

export function QuoteFormalizationFields({
  mode,
  templateId,
  templates,
  disabled,
  onModeChange,
  onTemplateChange,
}: QuoteFormalizationFieldsProps) {
  const { t } = useTranslation('projects')
  const quoteTemplates = templates.filter(
    (tpl) =>
      tpl.category === 'quote' &&
      (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
      !!tpl.id,
  )

  return (
    <div className="space-y-3">
      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">
          {t('projects.commercial.formalization_label', 'Formalització')}
        </span>
        <select
          className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
          value={mode}
          disabled={disabled}
          onChange={(e) => onModeChange(e.target.value as FormalizationMode)}
        >
          {FORMALIZATION_MODES.map((value) => (
            <option key={value} value={value}>
              {value === 'separate_agreement'
                ? t(
                    'projects.commercial.formalization_separate',
                    'Després d’acceptar, preparar contracte',
                  )
                : t(
                    'projects.commercial.formalization_signed',
                    'Un document: l’acceptació és el contracte',
                  )}
            </option>
          ))}
        </select>
        <span className="text-xs text-muted-foreground">
          {mode === 'separate_agreement'
            ? t(
                'projects.commercial.formalization_separate_help',
                'El pressupost queda com a annex. El contracte es prepara després, amb una segona firma. Acceptar no el crea sol.',
              )
            : t(
                'projects.commercial.formalization_signed_help',
                'El pressupost acceptat és l’encàrrec. No es generarà un segon document.',
              )}
        </span>
      </label>

      <label className="flex flex-col gap-1.5">
        <span className="text-sm font-medium">
          {t('projects.commercial.formalization_template', 'Plantilla d’aquest pressupost')}
        </span>
        <DocumentTemplateSelect
          templates={quoteTemplates.map((tpl) => ({
            id: tpl.id!,
            name: tpl.name,
            is_platform_default: tpl.is_platform_default,
          }))}
          value={templateId}
          onChange={onTemplateChange}
          disabled={disabled}
          emptyOptionLabel={t(
            'projects.commercial.formalization_template_default',
            'La plantilla activa del tenant',
          )}
          noTemplatesLabel={t(
            'projects.quotes.create_no_quote_template',
            'No hi ha plantilles de pressupost pròpies',
          )}
          searchPlaceholder={t(
            'projects.quotes.create_template_search',
            'Cerca plantilla de pressupost…',
          )}
        />
        <span className="text-xs text-muted-foreground">
          <Link to={QUOTE_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
            {t('projects.quotes.manage_templates', 'Gestionar plantilles')}
          </Link>
          {' · '}
          <Link
            to={commercialTemplatesHref('quote', { create: true })}
            className="text-indigo-600 hover:underline"
          >
            {t('projects.quotes.templates_new', 'Nova plantilla')}
          </Link>
        </span>
      </label>
    </div>
  )
}
