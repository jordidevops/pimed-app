import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  FileText,
  KeyRound,
  ListChecks,
  MessageSquare,
  ShieldCheck,
  Sparkles,
  Tags,
  Wallet,
} from 'lucide-react'
import { Button } from '@/components/ui/button'

type ChatSetupGuideProps = {
  canConfigure: boolean
}

const STEPS = [
  {
    icon: KeyRound,
    titleKey: 'setup.step1Title',
    titleFallback: 'Afegeix una clau',
    bodyKey: 'setup.step1Body',
    bodyFallback: 'OpenAI, Anthropic, Google Gemini o OpenRouter. La clau es desa xifrada i es verifica abans d\'usar-la.',
  },
  {
    icon: Sparkles,
    titleKey: 'setup.step2Title',
    titleFallback: 'Tria el model',
    bodyKey: 'setup.step2Body',
    bodyFallback: 'Un model per defecte per a tothom. A cada acció pots canviar-lo. Amb OpenRouter, una sola clau obre molts models.',
  },
  {
    icon: MessageSquare,
    titleKey: 'setup.step3Title',
    titleFallback: 'Fes-la servir on calgui',
    bodyKey: 'setup.step3Body',
    bodyFallback: 'Pregunta aquí en obert, o genera contingut al formulari on ja ets. On es modifiquen dades, es demana confirmació abans d\'aplicar els canvis.',
  },
] as const

const BENEFITS = [
  {
    icon: MessageSquare,
    titleKey: 'setup.benefitChatTitle',
    titleFallback: 'Consultes sobre les teves dades',
    bodyKey: 'setup.benefitChatBody',
    bodyFallback: 'Empleats, calendari, catàleg, plantilles o cobertura de competències. L\'assistent llegeix amb els teus permisos.',
  },
  {
    icon: ShieldCheck,
    titleKey: 'setup.benefitActionsTitle',
    titleFallback: 'Accions amb confirmació',
    bodyKey: 'setup.benefitActionsBody',
    bodyFallback: 'Pot proposar un contacte, un canvi d\'empleat, una alerta o un document. Res s\'aplica fins que ho confirmes.',
  },
  {
    icon: FileText,
    titleKey: 'setup.benefitInlineTitle',
    titleFallback: 'Generació al lloc de la feina',
    bodyKey: 'setup.benefitInlineBody',
    bodyFallback: 'A plantilles, checklists i tarifes hi ha botons que omplen el formulari obert, sense passar pel xat.',
  },
  {
    icon: Wallet,
    titleKey: 'setup.benefitLimitsTitle',
    titleFallback: 'Control d\'ús',
    bodyKey: 'setup.benefitLimitsBody',
    bodyFallback: 'Pots limitar les crides per hora o per dia i decidir qui pot utilitzar la IA.',
  },
] as const

const PLACES = [
  { icon: MessageSquare, key: 'setup.placeChat', fallback: 'Aquest xat, per preguntes obertes' },
  { icon: FileText, key: 'setup.placeTemplates', fallback: 'Idioma d\'una plantilla de document' },
  { icon: ListChecks, key: 'setup.placeChecklists', fallback: 'Punts i plantilles de checklist' },
  { icon: Tags, key: 'setup.placePricing', fallback: 'Tarifes i fulls de preus' },
] as const

const PROVIDERS = ['OpenAI', 'Anthropic', 'Google Gemini', 'OpenRouter'] as const

export function ChatSetupGuide({ canConfigure }: ChatSetupGuideProps) {
  const { t } = useTranslation('chat')

  return (
    <div className="bg-gradient-to-b from-indigo-50/80 via-background to-background dark:from-indigo-950/40">
      <div className="mx-auto max-w-5xl px-4 py-8 sm:px-6 sm:py-10">
        <header className="relative overflow-hidden rounded-2xl border bg-card px-6 py-8 shadow-sm sm:px-10">
          <div className="pointer-events-none absolute -right-20 -top-24 h-56 w-56 rounded-full bg-indigo-400/20 blur-3xl dark:bg-indigo-500/10" />
          <div className="relative max-w-2xl">
            <p className="inline-flex items-center gap-2 rounded-full border border-indigo-200 bg-indigo-50 px-3 py-1 text-xs font-medium text-indigo-700 dark:border-indigo-800 dark:bg-indigo-950/60 dark:text-indigo-200">
              <Sparkles className="h-3.5 w-3.5" />
              {t('setup.badge', 'La IA encara no està activada')}
            </p>
            <h1 className="mt-4 text-3xl font-semibold tracking-tight">
              {t('title', 'Assistent IA')}
            </h1>
            <p className="mt-3 text-base leading-relaxed text-muted-foreground">
              {t('setup.lead', 'El xat i els botons de generació comparteixen la mateixa configuració. Tu tries el proveïdor i el model; la clau es desa xifrada a la configuració i el cost el factura el proveïdor.')}
            </p>
            <div className="mt-6 flex flex-col items-start gap-2">
              {canConfigure ? (
                <>
                  <Button asChild>
                    <Link to="/settings/ai">{t('setup.cta', 'Configurar la IA')}</Link>
                  </Button>
                  <p className="text-sm text-muted-foreground">
                    {t('setup.ctaHint', 'Cal una clau verificada. Després, aquest xat i la resta d\'accions d\'IA quedaran disponibles.')}
                  </p>
                </>
              ) : (
                <p className="rounded-lg border bg-muted/40 px-3 py-2 text-sm text-muted-foreground">
                  {t('setup.askAdmin', 'Només un propietari o gestor pot activar-la. Demana-li que afegeixi una clau a Configuració → IA.')}
                </p>
              )}
            </div>
          </div>
        </header>

        <section className="mt-8">
          <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">
            {t('setup.stepsTitle', 'Com s\'activa')}
          </h2>
          <ol className="mt-3 grid gap-3 sm:grid-cols-3">
            {STEPS.map((step, index) => {
              const Icon = step.icon
              return (
                <li key={step.titleKey} className="rounded-xl border bg-card p-4">
                  <div className="flex items-center gap-2">
                    <span className="flex h-7 w-7 items-center justify-center rounded-full bg-indigo-600 text-xs font-semibold text-white">
                      {index + 1}
                    </span>
                    <Icon className="h-4 w-4 text-indigo-600 dark:text-indigo-300" />
                  </div>
                  <p className="mt-3 font-medium">{t(step.titleKey, step.titleFallback)}</p>
                  <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                    {t(step.bodyKey, step.bodyFallback)}
                  </p>
                </li>
              )
            })}
          </ol>
        </section>

        <section className="mt-8">
          <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">
            {t('setup.benefitsTitle', 'Què hi guanyes')}
          </h2>
          <ul className="mt-3 grid gap-3 sm:grid-cols-2">
            {BENEFITS.map((benefit) => {
              const Icon = benefit.icon
              return (
                <li key={benefit.titleKey} className="flex gap-3 rounded-xl border bg-card p-4">
                  <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-indigo-50 text-indigo-700 dark:bg-indigo-950/70 dark:text-indigo-200">
                    <Icon className="h-4 w-4" />
                  </span>
                  <div>
                    <p className="font-medium">{t(benefit.titleKey, benefit.titleFallback)}</p>
                    <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                      {t(benefit.bodyKey, benefit.bodyFallback)}
                    </p>
                  </div>
                </li>
              )
            })}
          </ul>
        </section>

        <section className="mt-8 grid gap-3 lg:grid-cols-[1.4fr_1fr]">
          <div className="rounded-xl border border-indigo-200/80 bg-indigo-50/70 p-5 dark:border-indigo-900 dark:bg-indigo-950/30">
            <div className="flex items-center gap-2 font-medium">
              <Wallet className="h-4 w-4 text-indigo-700 dark:text-indigo-200" />
              {t('setup.costTitle', 'Qui paga la IA')}
            </div>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              {t('setup.costBody', 'Es paga per ús al proveïdor que configuris, no a l\'app. Al compte d\'aquest proveïdor pots consultar l\'ús i el cost.')}
            </p>
            <p className="mt-4 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {t('setup.providersTitle', 'Proveïdors disponibles')}
            </p>
            <ul className="mt-2 flex flex-wrap gap-2">
              {PROVIDERS.map((name) => (
                <li
                  key={name}
                  className="rounded-full border bg-background px-3 py-1 text-sm"
                >
                  {name}
                </li>
              ))}
            </ul>
          </div>

          <div className="rounded-xl border bg-card p-5">
            <p className="font-medium">{t('setup.placesTitle', 'On apareix')}</p>
            <ul className="mt-3 space-y-2.5">
              {PLACES.map((place) => {
                const Icon = place.icon
                return (
                  <li key={place.key} className="flex items-start gap-2 text-sm text-muted-foreground">
                    <Icon className="mt-0.5 h-4 w-4 shrink-0 text-foreground" />
                    <span>{t(place.key, place.fallback)}</span>
                  </li>
                )
              })}
            </ul>
          </div>
        </section>

        {canConfigure && (
          <div className="mt-8 flex justify-start">
            <Button asChild variant="outline">
              <Link to="/settings/ai">{t('setup.cta', 'Configurar la IA')}</Link>
            </Button>
          </div>
        )}
      </div>
    </div>
  )
}
