import type { CalculatorFragmentKind } from '@/features/commercial/utils/calculatorAi'

export type CalculatorAiExampleChip = {
  id: string
  label: string
  prompt: string
}

/** Pastilles de prompt complet per seccions IA (fil operatiu + peces soltes). */
export const AI_EXAMPLE_CHIPS: Record<CalculatorFragmentKind, CalculatorAiExampleChip[]> = {
  parameter: [
    {
      id: 'distance_km',
      label: 'Distància km',
      prompt:
        'Afegeix un paràmetre distance_km de tipus number, obligatori, mínim 0, unitat km, etiqueta «Distància».',
    },
    {
      id: 'hours',
      label: 'Hores',
      prompt:
        'Afegeix un paràmetre hours de tipus number, obligatori, mínim 0, unitat h, etiqueta «Hores».',
    },
    {
      id: 'power_kw',
      label: 'Potència kW',
      prompt:
        'Afegeix un paràmetre power_kw de tipus number, obligatori, mínim 0, unitat kW, etiqueta «Potència».',
    },
  ],
  constant: [
    {
      id: 'labor_eur_h',
      label: '€/hora',
      prompt:
        'Afegeix una constant labor_eur_h de tipus money amb valor 45, etiqueta «€/hora mà d’obra».',
    },
    {
      id: 'travel_eur_km',
      label: '€/km',
      prompt:
        'Afegeix una constant travel_eur_km de tipus money amb valor 0.45, etiqueta «€/km desplaçament».',
    },
    {
      id: 'fuel_eur_l',
      label: '€/l benzina',
      prompt:
        'Afegeix una tarifa fuel_eur_l (€/l benzina). Si no dic el preu, estima un valor de mercat ES raonable amb assumed:true.',
    },
  ],
  line: [
    {
      id: 'labor_line',
      label: 'Mà d’obra',
      prompt:
        'Afegeix una línia de servei «Mà d’obra» (key labor): quantitat = paràmetre hours, preu unitari = constant labor_eur_h, unitat h, descompte 0, IVA 21%.',
    },
    {
      id: 'travel_km_line',
      label: 'Desplaçament €/km',
      prompt:
        'Afegeix una línia de servei «Desplaçament» (key travel_km): quantitat = paràmetre distance_km, preu unitari = constant travel_eur_km, unitat km, descompte 0, IVA 21%.',
    },
    {
      id: 'travel_fee_line',
      label: 'Desplaçament trams',
      prompt:
        'Afegeix una línia de servei «Desplaçament» (key travel_fee): quantitat = 1, preu = lookup/tier de la taula travel camp eur_base (segons distance_km), descompte 0, IVA 21%. La taula travel ja ha d’existir.',
    },
  ],
  table: [
    {
      id: 'travel_tiers',
      label: 'Trams km',
      prompt:
        'Afegeix una taula travel de tipus tier amb input distance_km, bound_column max_km i columnes de dades eur_base. Files: max_km 15 → eur_base 0; max_km 40 → eur_base 35; max_km null → eur_base 55.',
    },
  ],
}
