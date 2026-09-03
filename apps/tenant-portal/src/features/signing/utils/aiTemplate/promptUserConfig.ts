/** Opcions configurables al pas 1 del wizard abans de generar el prompt. */
export type SignerCountOption = 'none' | 'one' | 'two' | 'three_plus'

export interface AiPromptUserConfig {
  /** Quantes persones han de signar (orientació per a la IA). */
  signerCount: SignerCountOption
  /** Claus de rol del catàleg que el document ha d'incloure (worker, client_signatory, …). */
  roleKeys: string[]
  /** Notes addicionals (clàusules, imports, terminologia sectorial). */
  notes?: string
  /** Recomana path-based per nom/DNI/càrrec ({{ worker.full_name }}). */
  preferPathBasedIdentity: boolean
  /** Inclou camps de signatura al contingut. */
  includeSignatureFields: boolean
  /** Document intern sense signatura (informes, registres). */
  internalDocumentOnly: boolean
}

export const DEFAULT_AI_PROMPT_CONFIG: AiPromptUserConfig = {
  signerCount: 'two',
  roleKeys: ['worker', 'hr_manager'],
  notes: '',
  preferPathBasedIdentity: true,
  includeSignatureFields: true,
  internalDocumentOnly: false,
}

export function signerCountLabel(count: SignerCountOption): string {
  switch (count) {
    case 'none': return 'Cap signatura'
    case 'one': return '1 signant'
    case 'two': return '2 signants'
    case 'three_plus': return '3 o més signants'
  }
}
