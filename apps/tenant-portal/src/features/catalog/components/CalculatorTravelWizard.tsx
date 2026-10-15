import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import type { Constant, Definition, Expr, LineDef, LookupTable, Parameter } from '@pimed/price-calculator'
import { KEY_RE, resolveLocale } from '@pimed/price-calculator'

type TravelMode = 'per_km' | 'tiers'

type Props = {
  open: boolean
  onClose: () => void
  definition: Definition
  /** Prefill: clau de paràmetre de distància ja existent. */
  preferredDistanceKey?: string | null
  onApply: (next: Definition) => void
}

function round3(value: Expr): Expr {
  return { op: 'round', decimals: 3, mode: 'half_away_from_zero', value }
}

function round2(value: Expr): Expr {
  return { op: 'round', decimals: 2, mode: 'half_away_from_zero', value }
}

function humanKeyOption(label: { ca?: string; es?: string; en?: string } | undefined, key: string) {
  const human = resolveLocale(label, 'ca') || key
  return human === key ? key : `${human} (${key})`
}

function isDistanceLike(p: Parameter): boolean {
  if (p.unit?.toLowerCase() === 'km') return true
  const k = p.key.toLowerCase()
  return k.includes('distance') || k.includes('distancia') || k.includes('km')
}

export function CalculatorTravelWizard({
  open,
  onClose,
  definition,
  preferredDistanceKey = null,
  onApply,
}: Props) {
  const { t } = useTranslation(['catalog', 'common'])
  const { toast } = useToast()
  const [mode, setMode] = useState<TravelMode>('per_km')
  const [distanceKey, setDistanceKey] = useState('')
  const [eurPerKm, setEurPerKm] = useState('0.45')
  const [lineName, setLineName] = useState('Desplaçament')

  const distanceCandidates = useMemo(
    () => (definition.parameters ?? []).filter(isDistanceLike),
    [definition.parameters],
  )

  useEffect(() => {
    if (!open) return
    setMode('per_km')
    setEurPerKm('0.45')
    setLineName('Desplaçament')
    const preferred =
      preferredDistanceKey &&
      definition.parameters.some((p) => p.key === preferredDistanceKey)
        ? preferredDistanceKey
        : distanceCandidates[0]?.key ??
          definition.parameters.find((p) => p.key === 'distance_km')?.key ??
          ''
    setDistanceKey(preferred)
  }, [open, preferredDistanceKey, definition.parameters, distanceCandidates])

  function fail(message: string) {
    toast({ variant: 'destructive', description: message })
  }

  function ensureDistanceParam(next: Definition, key: string): string {
    const existing = next.parameters.find((p) => p.key === key)
    if (existing) return existing.key
    if (!KEY_RE.test(key)) {
      throw new Error(
        t('catalog.calculators.wizard_bad_key', 'Clau tècnica invàlida.'),
      )
    }
    const p: Parameter = {
      key,
      type: 'number',
      required: true,
      min: 0,
      unit: 'km',
      label: { ca: 'Distància' },
    }
    next.parameters.push(p)
    return key
  }

  function ensureEurPerKmConst(next: Definition): string {
    const key = 'travel_eur_km'
    const existing = next.constants?.find((c) => c.key === key)
    if (existing) return key
    const raw = eurPerKm.trim()
    const n = raw === '' ? NaN : Number(raw.replace(',', '.'))
    const c: Constant = {
      key,
      type: 'money',
      value: Number.isFinite(n) ? n : null,
      assumed: !Number.isFinite(n),
      label: { ca: '€/km desplaçament' },
    }
    next.constants = next.constants ?? []
    next.constants.push(c)
    return key
  }

  function ensureTravelTable(next: Definition, inputKey: string): string {
    const key = 'travel'
    const existing = next.tables?.find((tb) => tb.key === key)
    if (existing) return key
    const table: LookupTable = {
      key,
      lookup: 'tier',
      input: inputKey,
      bound_column: 'max_km',
      column_help: {
        max_km: {
          ca: 'Límit superior del tram (buit a l’última fila = sense límit)',
        },
        eur_base: { ca: 'Import en € d’aquest tram' },
      },
      rows: [
        { max_km: 15, eur_base: 0 },
        { max_km: 40, eur_base: 35 },
        { max_km: null, eur_base: 55 },
      ],
    }
    next.tables = next.tables ?? []
    next.tables.push(table)
    return key
  }

  function submit() {
    try {
      const next = structuredClone(definition)
      next.parameters = next.parameters ?? []
      next.constants = next.constants ?? []
      next.tables = next.tables ?? []
      next.lines = next.lines ?? []

      const distKey = ensureDistanceParam(next, distanceKey.trim() || 'distance_km')
      const taxExpr: Expr = { op: 'const', value: 21 }

      if (mode === 'per_km') {
        const lineKey = 'travel_km'
        if (next.lines.some((l) => l.key === lineKey)) {
          fail(
            t(
              'catalog.calculators.travel_line_exists',
              'Ja existeix la línia travel_km. Edita-la o treu-la abans.',
            ),
          )
          return
        }
        const constKey = ensureEurPerKmConst(next)
        const line: LineDef = {
          key: lineKey,
          name: { ca: lineName.trim() || 'Desplaçament' },
          kind: 'service',
          unit: 'km',
          quantity: round3({ op: 'param', key: distKey }),
          unit_price: round2({ op: 'const_ref', key: constKey }),
          discount_pct: { op: 'const', value: 0 },
          tax_rate: taxExpr,
        }
        next.lines.push(line)
      } else {
        const lineKey = 'travel_fee'
        if (next.lines.some((l) => l.key === lineKey)) {
          fail(
            t(
              'catalog.calculators.travel_fee_exists',
              'Ja existeix la línia travel_fee. Edita-la o treu-la abans.',
            ),
          )
          return
        }
        const tableKey = ensureTravelTable(next, distKey)
        const line: LineDef = {
          key: lineKey,
          name: { ca: lineName.trim() || 'Desplaçament' },
          kind: 'service',
          unit: 'u',
          quantity: round3({ op: 'const', value: 1 }),
          unit_price: round2({
            op: 'lookup_tier',
            table: tableKey,
            value: { op: 'row', field: 'eur_base' },
          }),
          discount_pct: { op: 'const', value: 0 },
          tax_rate: taxExpr,
        }
        next.lines.push(line)
      }

      onApply(next)
      onClose()
    } catch (err) {
      fail(err instanceof Error ? err.message : t('common:error', 'Error'))
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('catalog.calculators.travel_wizard_title', 'Desplaçament')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'catalog.calculators.travel_wizard_desc',
              'Tria com cobres el desplaçament. L’assistent crea el que falte (paràmetre, tarifa o taula i la línia).',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-1">
          <div className="space-y-2">
            <Label>
              {t('catalog.calculators.travel_how', 'Com cobres el desplaçament?')}
            </Label>
            <div className="space-y-2">
              <label className="flex cursor-pointer items-start gap-2 rounded-md border border-border p-2.5 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                <input
                  type="radio"
                  name="travel-mode"
                  className="mt-1"
                  checked={mode === 'per_km'}
                  onChange={() => setMode('per_km')}
                />
                <span className="text-sm">
                  <span className="font-medium">
                    {t('catalog.calculators.travel_mode_km', 'Per quilòmetre')}
                  </span>
                  <span className="mt-0.5 block text-muted-foreground">
                    {t(
                      'catalog.calculators.travel_mode_km_help',
                      'A la línia es veuen els km: Distància × €/km.',
                    )}
                  </span>
                </span>
              </label>
              <label className="flex cursor-pointer items-start gap-2 rounded-md border border-border p-2.5 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                <input
                  type="radio"
                  name="travel-mode"
                  className="mt-1"
                  checked={mode === 'tiers'}
                  onChange={() => setMode('tiers')}
                />
                <span className="text-sm">
                  <span className="font-medium">
                    {t(
                      'catalog.calculators.travel_mode_tiers',
                      'Import fix per trams de km',
                    )}
                  </span>
                  <span className="mt-0.5 block text-muted-foreground">
                    {t(
                      'catalog.calculators.travel_mode_tiers_help',
                      'Quantitat 1 i preu segons taula de trams (p. ex. fins 15 km gratis).',
                    )}
                  </span>
                </span>
              </label>
            </div>
          </div>

          <div className="space-y-1">
            <Label>
              {t('catalog.calculators.travel_line_name', 'Nom de la línia')}
            </Label>
            <Input value={lineName} onChange={(e) => setLineName(e.target.value)} />
          </div>

          <div className="space-y-1">
            <Label>
              {t(
                'catalog.calculators.travel_distance_param',
                'Paràmetre de distància',
              )}
            </Label>
            {(definition.parameters ?? []).length > 0 ? (
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
                value={
                  distanceKey ||
                  (definition.parameters.some((p) => p.key === 'distance_km')
                    ? 'distance_km'
                    : '')
                }
                onChange={(e) => setDistanceKey(e.target.value)}
              >
                {!definition.parameters.some((p) => p.key === 'distance_km') ? (
                  <option value="">
                    {t(
                      'catalog.calculators.travel_create_distance',
                      'Crear Distància (distance_km)',
                    )}
                  </option>
                ) : null}
                {(definition.parameters ?? []).map((p) => (
                  <option key={p.key} value={p.key}>
                    {humanKeyOption(p.label, p.key)}
                    {p.unit ? ` · ${p.unit}` : ''}
                  </option>
                ))}
              </select>
            ) : (
              <p className="text-sm text-muted-foreground">
                {t(
                  'catalog.calculators.travel_will_create_distance',
                  'Es crearà el paràmetre Distància (distance_km).',
                )}
              </p>
            )}
          </div>

          {mode === 'per_km' ? (
            <div className="space-y-1">
              <Label>
                {t('catalog.calculators.travel_eur_km', 'Tarifa €/km')}
              </Label>
              <Input
                type="number"
                step="0.01"
                min="0"
                value={eurPerKm}
                onChange={(e) => setEurPerKm(e.target.value)}
                placeholder="0.45"
              />
              <p className="text-xs text-muted-foreground">
                {t(
                  'catalog.calculators.travel_eur_km_help',
                  'Es desa com a constant travel_eur_km. Si ja existeix, es reutilitza.',
                )}
              </p>
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              {t(
                'catalog.calculators.travel_tiers_help',
                'Es crearà (si cal) la taula travel amb trams d’exemple: 15→0 €, 40→35 €, més enllà→55 €. Després pots editar els imports.',
              )}
            </p>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={submit}>
            {t('catalog.calculators.travel_create', 'Crear desplaçament')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
