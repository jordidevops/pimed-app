import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertTriangle } from 'lucide-react'
import {
  computeLocaleOverwriteDiff,
  type LocaleOverwriteSnapshot,
} from '../utils/aiTemplate/overwriteDiff'

interface TemplateLocaleOverwriteDiffProps {
  templateType: 'html' | 'docx'
  existing: LocaleOverwriteSnapshot
  incoming: LocaleOverwriteSnapshot
}

function SchemaChangesSection({
  title,
  added,
  removed,
  changed,
  labels,
}: {
  title: string
  added: string[]
  removed: string[]
  changed: Array<{ key: string; field: string; before: string; after: string }>
  labels: {
    added: string
    removed: string
    changed: string
    none: string
  }
}) {
  const hasChanges = added.length > 0 || removed.length > 0 || changed.length > 0

  return (
    <section className="space-y-2">
      <h4 className="text-sm font-semibold text-foreground">{title}</h4>
      {!hasChanges ? (
        <p className="text-xs text-muted-foreground">{labels.none}</p>
      ) : (
        <div className="space-y-2 text-xs">
          {added.length > 0 && (
            <div className="rounded-md bg-emerald-50 border border-emerald-200 px-2.5 py-2">
              <p className="font-medium text-emerald-900">{labels.added}</p>
              <p className="font-mono text-emerald-800 mt-1">{added.join(', ')}</p>
            </div>
          )}
          {removed.length > 0 && (
            <div className="rounded-md bg-red-50 border border-red-200 px-2.5 py-2">
              <p className="font-medium text-red-900">{labels.removed}</p>
              <p className="font-mono text-red-800 mt-1">{removed.join(', ')}</p>
            </div>
          )}
          {changed.length > 0 && (
            <div className="rounded-md bg-amber-50 border border-amber-200 px-2.5 py-2 space-y-1.5">
              <p className="font-medium text-amber-900">{labels.changed}</p>
              {changed.map(item => (
                <p key={`${item.key}-${item.field}`} className="font-mono text-amber-900">
                  <span className="font-semibold">{item.key}</span>
                  {' · '}
                  {item.field}: {item.before} → {item.after}
                </p>
              ))}
            </div>
          )}
        </div>
      )}
    </section>
  )
}

export function TemplateLocaleOverwriteDiff({
  templateType,
  existing,
  incoming,
}: TemplateLocaleOverwriteDiffProps) {
  const { t } = useTranslation('signing')

  const diff = useMemo(
    () => computeLocaleOverwriteDiff(existing, incoming, templateType),
    [existing, incoming, templateType],
  )

  return (
    <div className="rounded-lg border border-amber-300 bg-amber-50/60 p-4 space-y-4">
      <div className="flex items-start gap-2">
        <AlertTriangle className="h-4 w-4 text-amber-700 mt-0.5 shrink-0" />
        <div>
          <p className="text-sm font-semibold text-amber-900">
            {t('aiWizard.overwriteTitle', 'Revisió abans de sobreescriure')}
          </p>
          <p className="text-xs text-amber-800 mt-0.5">
            {diff.hasChanges
              ? t('aiWizard.overwriteSummary', 'Aquests canvis substituiran el contingut actual d\'aquest idioma.')
              : t('aiWizard.overwriteNoChanges', 'No s\'han detectat canvis respecte al contingut actual. Pots confirmar igualment.')}
          </p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <SchemaChangesSection
          title={t('locale.signingRoles', 'Rols de document')}
          added={diff.roles.added}
          removed={diff.roles.removed}
          changed={diff.roles.changed}
          labels={{
            added: t('aiWizard.diffAdded', 'Nous rols'),
            removed: t('aiWizard.diffRemoved', 'Rols eliminats'),
            changed: t('aiWizard.diffChanged', 'Rols modificats'),
            none: t('aiWizard.diffNone', 'Sense canvis'),
          }}
        />
        <SchemaChangesSection
          title={t('locale.variablesSchema', 'Variables de la plantilla')}
          added={diff.variables.added}
          removed={diff.variables.removed}
          changed={diff.variables.changed}
          labels={{
            added: t('aiWizard.diffAddedVars', 'Noves variables'),
            removed: t('aiWizard.diffRemovedVars', 'Variables eliminades'),
            changed: t('aiWizard.diffChangedVars', 'Variables modificades'),
            none: t('aiWizard.diffNone', 'Sense canvis'),
          }}
        />
      </div>

      {templateType === 'html' && diff.html && (
        <section className="space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h4 className="text-sm font-semibold text-foreground">
              {t('locale.htmlContent', 'Contingut HTML')}
            </h4>
            <p className="text-xs text-muted-foreground font-mono">
              {diff.html.oldLength.toLocaleString()} → {diff.html.newLength.toLocaleString()} {t('locale.chars', 'caràcters')}
            </p>
          </div>

          {!diff.html.changed ? (
            <p className="text-xs text-muted-foreground">{t('aiWizard.diffHtmlSame', 'El contingut HTML és equivalent.')}</p>
          ) : (
            <div className="rounded-md border bg-background max-h-56 overflow-auto">
              <pre className="text-[11px] leading-relaxed p-2 font-mono whitespace-pre-wrap break-all">
                {diff.html.lines.map((line, idx) => (
                  <div
                    key={idx}
                    className={
                      line.type === 'add'
                        ? 'bg-emerald-100 text-emerald-950'
                        : line.type === 'remove'
                          ? 'bg-red-100 text-red-950 line-through'
                          : 'text-muted-foreground'
                    }
                  >
                    {line.type === 'add' ? '+ ' : line.type === 'remove' ? '- ' : '  '}
                    {line.text || ' '}
                  </div>
                ))}
              </pre>
              {diff.html.truncated && (
                <p className="text-[11px] text-muted-foreground px-2 py-1 border-t">
                  {t('aiWizard.diffTruncated', 'Diff truncat per longitud. Revisa la vista prèvia per al detall complet.')}
                </p>
              )}
            </div>
          )}
        </section>
      )}
    </div>
  )
}
