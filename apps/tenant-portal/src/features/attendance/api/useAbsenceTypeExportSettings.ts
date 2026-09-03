import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import {
  createAbsenceTypeSubtype,
  saveAbsenceTypeExportSettings,
  type AbsenceParentKey,
} from './shiftsService'

export function useSaveAbsenceTypeExportSettings() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: saveAbsenceTypeExportSettings,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['attendance', 'absence-type-configs'] })
      toast({
        title: t('config.absence_types.save_ok', 'Codi d’exportació desat'),
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('config.absence_types.save_error', 'No s’ha pogut desar'),
        description: err.message,
      })
    },
  })
}

export function useCreateAbsenceTypeSubtype() {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: {
      absence_type: string
      parent_key: AbsenceParentKey
      subtype_key: string
      name_i18n: Record<string, string>
      export_code: string
    }) => createAbsenceTypeSubtype(params),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['attendance', 'absence-type-configs'] })
      toast({
        title: t('config.absence_types.subtype_created', 'Subtipus creat'),
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('config.absence_types.subtype_error', 'No s’ha pogut crear el subtipus'),
        description: err.message,
      })
    },
  })
}
