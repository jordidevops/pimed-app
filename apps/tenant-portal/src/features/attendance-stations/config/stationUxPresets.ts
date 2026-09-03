export type StationUxPreset = 'custom' | 'estricte' | 'rapid_supervisat' | 'qr'

export const STATION_UX_PRESET_OPTIONS: Array<{ value: StationUxPreset; label: string; hint: string }> = [
  {
    value: 'estricte',
    label: 'Estricte (vestuari)',
    hint: 'Document-first, confirmació de nom, noms emmascarats, auto-blank 90s, historial off.',
  },
  {
    value: 'rapid_supervisat',
    label: 'Ràpid supervisat',
    hint: 'Llista amb confirmació de nom, auto-blank 180s, sense emmascarar (supervisor present).',
  },
  {
    value: 'qr',
    label: 'Només QR',
    hint: 'Només mètode QR, confirmació de nom, noms emmascarats, auto-blank 120s.',
  },
  {
    value: 'custom',
    label: 'Personalitzat',
    hint: 'Configura cada camp manualment (el servidor valida combinacions insegures).',
  },
]
