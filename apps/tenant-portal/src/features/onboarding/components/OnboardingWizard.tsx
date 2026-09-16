import { useState, useEffect, useRef } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { CheckCircle2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { setActiveTenantId } from '@/lib/supabase'
import { getSectorProfiles, applySectorRecipe } from '../api/onboardingService'
import type { SectorProfile } from '../api/onboardingService'

// ─── Constants ────────────────────────────────────────────────────────────────

const TOTAL_STEPS = 3

// ─── ArchetypeCard ────────────────────────────────────────────────────────────

interface ArchetypeCardProps {
  profile: SectorProfile
  selected: boolean
  onSelect: () => void
  showSeedCount: boolean
}

function ArchetypeCard({ profile, selected, onSelect, showSeedCount }: ArchetypeCardProps) {
  const { t } = useTranslation('onboarding')

  // Map archetype key → i18n name (fallback to DB display_name_ca)
  const archetypeNames: Record<string, string> = {
    field_service:  t('onboarding.archetype_field_service_name', profile.display_name_ca ?? ''),
    practice:       t('onboarding.archetype_practice_name', profile.display_name_ca ?? ''),
    hospitality:    t('onboarding.archetype_hospitality_name', profile.display_name_ca ?? ''),
    workshop_maker: t('onboarding.archetype_workshop_maker_name', profile.display_name_ca ?? ''),
    generic:        t('onboarding.archetype_generic_name', profile.display_name_ca ?? ''),
  }

  const displayName = profile.archetype ? (archetypeNames[profile.archetype] ?? profile.display_name_ca) : profile.display_name_ca
  const seedCount = profile.catalog_seed_count ?? 0

  return (
    <button
      type="button"
      onClick={onSelect}
      className={[
        'group relative flex flex-col items-center gap-3 rounded-2xl border-2 p-6 text-center transition-all duration-150',
        'hover:border-indigo-400 hover:bg-indigo-50/50 dark:hover:bg-indigo-950/30 focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500',
        selected
          ? 'border-indigo-500 bg-indigo-50 dark:bg-indigo-950/40 shadow-md'
          : 'border-border bg-card',
      ].join(' ')}
      aria-pressed={selected}
    >
      {selected && (
        <CheckCircle2 className="absolute top-3 right-3 h-5 w-5 text-indigo-500" />
      )}

      {/* Icon */}
      <span className="text-4xl leading-none select-none" role="img" aria-label={displayName ?? ''}>
        {profile.icon ?? '🏢'}
      </span>

      {/* Name */}
      <span className="font-semibold text-foreground text-sm leading-tight">
        {displayName}
      </span>

      {/* Description */}
      {profile.description_ca && (
        <span className="text-xs text-muted-foreground leading-snug line-clamp-2">
          {profile.description_ca}
        </span>
      )}

      {/* Catalog seed count (first-time only; re-apply does not re-seed) */}
      {showSeedCount && seedCount > 0 && (
        <span className="mt-1 rounded-full bg-indigo-100 dark:bg-indigo-900/50 px-2.5 py-0.5 text-[11px] text-indigo-700 dark:text-indigo-300 font-medium">
          {t('onboarding.catalog_seed_count_badge', '+{{count}} ítems catàleg', { count: seedCount })}
        </span>
      )}
    </button>
  )
}

// ─── Step indicators ──────────────────────────────────────────────────────────

interface StepDotsProps {
  currentStep: number
  total: number
}

function StepDots({ currentStep, total }: StepDotsProps) {
  return (
    <div className="flex items-center gap-2 justify-center">
      {Array.from({ length: total }, (_, i) => (
        <div
          key={i}
          className={[
            'rounded-full transition-all duration-200',
            i + 1 === currentStep
              ? 'w-6 h-2 bg-indigo-500'
              : i + 1 < currentStep
              ? 'w-2 h-2 bg-indigo-300'
              : 'w-2 h-2 bg-border',
          ].join(' ')}
        />
      ))}
    </div>
  )
}

// ─── OnboardingWizard ─────────────────────────────────────────────────────────

export function OnboardingWizard() {
  const { t } = useTranslation('onboarding')
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  const isReconfigure = Boolean(activeTenant?.sector_profile_id)
  const totalSteps = isReconfigure ? 2 : TOTAL_STEPS
  const exitTo = searchParams.get('reconfigure') === '1' ? '/settings/config' : '/dashboard'

  const [step, setStep] = useState(1)
  const [selectedProfile, setSelectedProfile] = useState<SectorProfile | null>(null)
  const [companyName, setCompanyName] = useState(activeTenant?.name ?? '')
  // Ref per sincronitzar el prefill UNA sola vegada quan activeTenant arriba tard
  // (p.ex. navegació directa a /onboarding sense passar pel guard d'AppLayout).
  // No sobreescriu edicions manuals de l'usuari.
  const companyNameInitializedRef = useRef(false)
  useEffect(() => {
    if (!companyNameInitializedRef.current && activeTenant?.name) {
      companyNameInitializedRef.current = true
      setCompanyName(activeTenant.name)
    }
  }, [activeTenant?.name])
  const [companyNameError, setCompanyNameError] = useState('')
  const [isApplying, setIsApplying] = useState(false)
  const [applyError, setApplyError] = useState('')

  const { data: profiles = [], isLoading: profilesLoading, isError: profilesError, refetch: refetchProfiles } = useQuery<SectorProfile[]>({
    queryKey: ['sector_profiles'],
    queryFn: getSectorProfiles,
  })

  useEffect(() => {
    if (selectedProfile || !activeTenant?.sector_profile_id || profiles.length === 0) return
    const current = profiles.find((p) => p.id === activeTenant.sector_profile_id)
    if (current) setSelectedProfile(current)
  }, [profiles, activeTenant?.sector_profile_id, selectedProfile])

  // ─── Handlers ──────────────────────────────────────────────────────────────

  function handleSelectProfile(profile: SectorProfile) {
    setSelectedProfile(profile)
  }

  function handleNextFromStep1() {
    if (!selectedProfile) return
    setStep(2)
  }

  function handleNextFromStep2() {
    const trimmed = companyName.trim()
    if (!trimmed) {
      setCompanyNameError(t('onboarding.company_name_required', 'El nom de l\'empresa és obligatori.'))
      return
    }
    setCompanyNameError('')
    setStep(3)
  }

  async function handleApply() {
    if (!selectedProfile || !activeTenant) return
    setIsApplying(true)
    setApplyError('')
    try {
      // Defensa addicional: assegura el context de tenant abans de la RPC.
      setActiveTenantId(activeTenant.id)
      await applySectorRecipe(
        selectedProfile.id!,
        isReconfigure ? undefined : (companyName.trim() || undefined),
        activeTenant.id,
      )
      await queryClient.invalidateQueries({ queryKey: ['tenants'] })
      navigate(exitTo, { replace: true })
    } catch (err) {
      setApplyError(t('onboarding.error_apply', 'No s\'ha pogut configurar el sector. Torna-ho a intentar.'))
      setIsApplying(false)
    }
  }

  // ─── Step 1: Sector selection ───────────────────────────────────────────────

  if (step === 1) {
    return (
      <div className="space-y-8">
        {/* Header */}
        <div className="text-center space-y-2">
          <h1 className="text-2xl font-bold text-foreground">
            {isReconfigure
              ? t('onboarding.reconfigure_title', 'Vols canviar de sector?')
              : t('onboarding.step_sector_title', 'Quin és el teu sector?')}
          </h1>
          <p className="text-muted-foreground text-sm max-w-md mx-auto">
            {isReconfigure
              ? t(
                  'onboarding.reconfigure_subtitle',
                  'Això actualitza el vocabulari i els menús (p. ex. ordres vs projectes). El catàleg existent no es buida.',
                )
              : t('onboarding.step_sector_subtitle', 'Triarem una configuració inicial adaptada al teu negoci.')}
          </p>
        </div>

        <StepDots currentStep={1} total={totalSteps} />

        {/* Archetype grid */}
        {profilesLoading ? (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
            {[1, 2, 3, 4, 5].map((i) => (
              <div key={i} className="h-44 rounded-2xl bg-muted animate-pulse" />
            ))}
          </div>
        ) : profilesError ? (
          <div className="flex flex-col items-center gap-4 py-8 text-center">
            <p className="text-sm text-destructive">
              {t('onboarding.error_load_profiles', "No s'han pogut carregar els sectors. Comprova la connexió.")}
            </p>
            <Button variant="outline" size="sm" onClick={() => refetchProfiles()}>
              {t('onboarding.btn_retry', 'Reintentar')}
            </Button>
          </div>
        ) : (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
            {profiles.map((profile) => (
              <ArchetypeCard
                key={profile.id}
                profile={profile}
                selected={selectedProfile?.id === profile.id}
                onSelect={() => handleSelectProfile(profile)}
                showSeedCount={!isReconfigure}
              />
            ))}
          </div>
        )}

        {/* Actions */}
        <div className={`flex pt-2 ${isReconfigure ? 'items-center justify-between' : 'justify-end'}`}>
          {isReconfigure && (
            <Button variant="ghost" onClick={() => navigate(exitTo)}>
              {t('onboarding.btn_cancel', 'Cancel·lar')}
            </Button>
          )}
          <Button
            onClick={handleNextFromStep1}
            disabled={!selectedProfile}
            size="lg"
            className="min-w-36"
          >
            {t('onboarding.btn_next', 'Continuar')}
          </Button>
        </div>
      </div>
    )
  }

  // ─── Step 2: Company name (first-time only) ─────────────────────────────────

  if (step === 2 && !isReconfigure) {
    return (
      <div className="space-y-8">
        {/* Header */}
        <div className="text-center space-y-2">
          <h1 className="text-2xl font-bold text-foreground">
            {t('onboarding.step_company_title', 'Confirma el nom de la teva empresa')}
          </h1>
          <p className="text-muted-foreground text-sm max-w-md mx-auto">
            {t('onboarding.step_company_subtitle', 'Podràs canviar-lo en qualsevol moment des de Configuració.')}
          </p>
        </div>

        <StepDots currentStep={2} total={TOTAL_STEPS} />

        {/* Recap del sector triat */}
        {selectedProfile && (
          <div className="flex items-center gap-3 rounded-xl border border-indigo-200 bg-indigo-50 dark:bg-indigo-950/30 dark:border-indigo-800 px-5 py-3 max-w-sm mx-auto">
            <span className="text-2xl" role="img" aria-label="">
              {selectedProfile.icon ?? '🏢'}
            </span>
            <span className="font-medium text-indigo-800 dark:text-indigo-200 text-sm">
              {selectedProfile.display_name_ca}
            </span>
          </div>
        )}

        {/* Company name input */}
        <div className="max-w-sm mx-auto space-y-2">
          <label htmlFor="ob-company-name" className="block text-sm font-medium text-foreground">
            {t('onboarding.company_name_label', "Nom de l'empresa")}
          </label>
          <Input
            id="ob-company-name"
            value={companyName}
            onChange={(e) => {
              setCompanyName(e.target.value)
              if (companyNameError) setCompanyNameError('')
            }}
            placeholder={t('onboarding.company_name_placeholder', 'Ex: Instal·lacions Garcia, SL')}
            className="text-base"
            autoFocus
          />
          {companyNameError && (
            <p role="alert" className="text-sm text-destructive">{companyNameError}</p>
          )}
        </div>

        {/* Catalog hint */}
        <p className="text-center text-xs text-muted-foreground">
          {(selectedProfile?.catalog_seed_count ?? 0) > 0
            ? t('onboarding.catalog_seed_hint', "S'afegiran {{count}} ítems al teu catàleg per començar.", { count: selectedProfile?.catalog_seed_count ?? 0 })
            : t('onboarding.catalog_seed_hint_empty', 'Podràs afegir ítems al catàleg quan vulguis.')}
        </p>

        {/* Actions */}
        <div className="flex items-center justify-between pt-2">
          <Button variant="ghost" onClick={() => setStep(1)}>
            {t('onboarding.btn_back', 'Enrere')}
          </Button>
          <Button onClick={handleNextFromStep2} size="lg" className="min-w-36">
            {t('onboarding.btn_next', 'Continuar')}
          </Button>
        </div>
      </div>
    )
  }

  // ─── Confirm (step 3 first-time, step 2 when reconfiguring) ─────────────────

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="text-center space-y-2">
        <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-green-100 dark:bg-green-900/30 mx-auto">
          <CheckCircle2 className="w-9 h-9 text-green-600 dark:text-green-400" />
        </div>
        <h1 className="text-2xl font-bold text-foreground">
          {isReconfigure
            ? t('onboarding.reconfigure_done_title', 'Confirma el canvi de sector')
            : t('onboarding.step_done_title', 'Tot a punt!')}
        </h1>
        <p className="text-muted-foreground text-sm max-w-md mx-auto">
          {isReconfigure
            ? t(
                'onboarding.reconfigure_done_subtitle',
                'Els noms dels mòduls i el menú s’adaptaran al sector nou. Les dades existents (catàleg, contactes, ordres) es conserven.',
              )
            : t('onboarding.step_done_subtitle', 'El teu espai de treball ja està configurat. Pots personalitzar-lo en qualsevol moment.')}
        </p>
      </div>

      <StepDots currentStep={isReconfigure ? 2 : 3} total={totalSteps} />

      {/* Summary card */}
      <div className="rounded-2xl border bg-card p-6 max-w-sm mx-auto space-y-4">
        <div className="flex items-center gap-3">
          <span className="text-2xl" role="img" aria-label="">
            {selectedProfile?.icon ?? '🏢'}
          </span>
          <div>
            <p className="text-xs text-muted-foreground uppercase tracking-wide font-medium">{t('onboarding.summary_sector_label', 'Sector')}</p>
            <p className="font-semibold text-foreground">{selectedProfile?.display_name_ca}</p>
          </div>
        </div>
        {!isReconfigure && (
          <div>
            <p className="text-xs text-muted-foreground uppercase tracking-wide font-medium">{t('onboarding.summary_company_label', 'Empresa')}</p>
            <p className="font-semibold text-foreground">{companyName}</p>
          </div>
        )}
        {isReconfigure ? (
          <div className="rounded-lg bg-amber-50 dark:bg-amber-950/40 px-3 py-2">
            <p className="text-xs text-amber-900 dark:text-amber-200">
              {t(
                'onboarding.reconfigure_catalog_note',
                'El catàleg no es torna a omplir: només es canvien etiquetes i menús.',
              )}
            </p>
          </div>
        ) : (
          (selectedProfile?.catalog_seed_count ?? 0) > 0 && (
            <div className="rounded-lg bg-muted/60 px-3 py-2">
              <p className="text-xs text-muted-foreground">
                {t('onboarding.catalog_seed_hint', "S'afegiran {{count}} ítems al teu catàleg per començar.", { count: selectedProfile?.catalog_seed_count ?? 0 })}
              </p>
            </div>
          )
        )}
      </div>

      {/* Error */}
      {applyError && (
        <p role="alert" className="text-center text-sm text-destructive">{applyError}</p>
      )}

      {/* Actions */}
      <div className="flex items-center justify-between pt-2">
        <Button variant="ghost" onClick={() => setStep(isReconfigure ? 1 : 2)} disabled={isApplying}>
          {t('onboarding.btn_back', 'Enrere')}
        </Button>
        <Button
          onClick={handleApply}
          disabled={isApplying}
          size="lg"
          className="min-w-44"
        >
          {isApplying
            ? t('onboarding.btn_applying', 'Configurant...')
            : isReconfigure
              ? t('onboarding.btn_save_sector', 'Desar sector')
              : t('onboarding.btn_finish', 'Entrar al tauler')}
        </Button>
      </div>
    </div>
  )
}
