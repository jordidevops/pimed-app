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

/**
 * Pastilles per «Generar / regenerar calculadora amb IA» (prompt comercial humà).
 * Alineades amb les plantilles del catàleg de plataforma + exemple simple €/h + €/km.
 */
export const AI_FULL_CREATE_CHIPS: CalculatorAiExampleChip[] = [
  {
    id: 'labor_km_simple',
    label: '€/h + €/km',
    prompt: 'Cobra 40 euros/hora i 1,2 euros/km a partir de 30km',
  },
  {
    id: 'site_visit',
    label: 'Visita tècnica',
    prompt:
      'Necessito una calculadora de visita tècnica. Em demanen els quilòmetres fins al client i quantes unitats de material porto. El desplaçament el cobro amb un import fix segons trams: fins a 15 km gratis, fins a 40 km un preu, i més lluny un altre. Els materials es cobren per unitat a un preu fix. Si no hi ha desplaçament o no porto material, aquella línia no ha de sortir al pressupost.',
  },
  {
    id: 'electrician',
    label: 'Electricista',
    prompt:
      'Vull pressupostar feines d’electricista. Em calen la distància en km i la potència en kW. El desplaçament va per trams de km (amb un mínim i, a partir d’un cert km, un extra per quilòmetre). La mà d’obra són hores que depenen de la potència (trams de kW) multiplicades pel meu €/hora. Tot amb IVA 21%.',
  },
  {
    id: 'blinds',
    label: 'Persianes m²',
    prompt:
      'Calculo persianes per m². Trien el model (PVC o alumini), l’amplada i l’alçada en cm i quantes unitats. El preu és €/m² del model, amb un mínim de m² per unitat. La quantitat és el producte de unitats per la superfície (o el mínim si la superfície és més petita).',
  },
  {
    id: 'elevator',
    label: 'Ascensors anual',
    prompt:
      'Manteniment anual d’ascensors: trien el tipus de tracció (elèctric o hidràulic) i el nombre de parades. Hi ha una quota base anual segons la tracció i un suplement per cada parada. Vull dues línies al pressupost: la base i el suplement.',
  },
  {
    id: 'horeca',
    label: 'HORECA mensual',
    prompt:
      'Manteniment mensual per restauració (HORECA). Em demanen els coberts i si tenen fred industrial (sense, càmera bàsica o càmera amb murals). La quota mensual depèn dels coberts per trams, i el fred és un suplement opcional que només surt si n’han triat.',
  },
]
