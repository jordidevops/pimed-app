import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { AlertCircle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { supabase } from '../../../lib/supabase'

interface DeadLetterAlertWidgetProps {
  tenantId: string | null
  siteId: string | null
}

export function DeadLetterAlertWidget({ tenantId, siteId }: DeadLetterAlertWidgetProps) {
  const { t } = useTranslation('email')

  const { data: errorCount = 0, isLoading } = useQuery({
    queryKey: ['email-logs-dead-letters', tenantId, siteId],
    queryFn: async () => {
      // Obtenir errors (dead letter) dels últims 7 dies
      const d = new Date()
      d.setDate(d.getDate() - 7)
      
      let query = supabase
        .from('email_logs')
        .select('id', { count: 'exact', head: true })
        .eq('tenant_id', tenantId!)
        .eq('is_dead_letter', true)
        .gte('created_at', d.toISOString())

      if (siteId) {
        query = query.eq('site_id', siteId)
      }

      const { count, error } = await query
      if (error) throw error
      return count ?? 0
    },
    enabled: !!tenantId,
    refetchInterval: 5 * 60 * 1000, // Cada 5 minuts
  })

  if (isLoading || errorCount === 0) return null

  return (
    <div className="bg-destructive/10 border border-destructive/20 rounded-xl p-4 flex items-start gap-3">
      <AlertCircle className="w-5 h-5 text-destructive shrink-0 mt-0.5" />
      <div className="flex-1">
        <h4 className="text-sm font-semibold text-destructive">
          {t('dashboard.dead_letters_title', 'Problemes d\'enviament de correu')}
        </h4>
        <p className="text-sm text-destructive/90 mt-1">
          {t('dashboard.dead_letters_desc', 'S\'han detectat {{count}} correus que no s\'han pogut enviar als destinataris i s\'han cancel·lat. Revisa l\'historial de correus.', { count: errorCount })}
        </p>
        <Link
          to="/settings/email"
          className="inline-block mt-2 text-sm font-medium text-destructive underline hover:text-destructive/80"
        >
          {t('dashboard.dead_letters_link', 'Veure historial de correus')}
        </Link>
      </div>
    </div>
  )
}
