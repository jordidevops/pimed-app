// ─── PDF field types ──────────────────────────────────────────────────────────

export type PdfFieldType =
  | 'signature'
  | 'initials'
  | 'text'
  | 'date'
  | 'checkbox'

export interface PdfField {
  /** Identificador únic del camp dins l'esquema */
  id:      string
  /** Número de pàgina (1-indexed) */
  page:    number
  /** Posició X en percentatge (0–100) de l'amplada de la pàgina */
  x:       number
  /** Posició Y en percentatge (0–100) de l'alçada de la pàgina */
  y:       number
  /** Amplada en percentatge de l'amplada de la pàgina */
  w:       number
  /** Alçada en percentatge de l'alçada de la pàgina */
  h:       number
  /** Tipus de camp */
  type:    PdfFieldType
  /** Rol de signant al que pertany (opcional; null = qualsevol) */
  role?:   string | null
  /** Etiqueta visible (opcional) */
  label?:  string | null
  /** Obligatori */
  required?: boolean
}
