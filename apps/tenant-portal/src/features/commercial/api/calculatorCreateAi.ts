import {
  EMPTY_CALCULATOR_DEFINITION,
  createCalculatorDefinition,
} from '@/features/commercial/api/calculatorService'

/** Path d’editor amb diàleg «crear amb IA» obert. */
export function calculatorAiCreatePath(definitionId: string): string {
  return `/catalog/calculators/${definitionId}?aiCreate=1`
}

/** Crea un esborrany buit i retorna l’id (el caller navega amb calculatorAiCreatePath). */
export async function createCalculatorForAi(input: {
  name: string
  description: string
}): Promise<string> {
  return createCalculatorDefinition({
    name: input.name,
    description: input.description,
    draftDefinition: EMPTY_CALCULATOR_DEFINITION,
    tags: [],
  })
}
