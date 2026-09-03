import { useMutation } from '@tanstack/react-query'
import { callSignDocumentRouter, type SignDocumentInput, type SignDocumentResult } from './signingService'

export function useSigningMutation() {
  return useMutation<SignDocumentResult, Error, SignDocumentInput>({
    mutationFn: callSignDocumentRouter,
  })
}
