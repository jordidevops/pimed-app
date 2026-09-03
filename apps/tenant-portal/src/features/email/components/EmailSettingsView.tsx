import { useTranslation } from 'react-i18next'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import { EmailGeneralTab } from './EmailGeneralTab'
import { EmailDomainsTab } from './EmailDomainsTab'
import { EmailLogsTab } from './EmailLogsTab'
import { EmailTemplatesTab } from './EmailTemplatesTab'
import { QuotaCard } from './QuotaCard'
import { useEmailConfig } from '../api/useEmailConfig'

interface EmailSettingsViewProps {
  tenantId: string
}

export function EmailSettingsView({ tenantId }: EmailSettingsViewProps) {
  const { t } = useTranslation('email')
  const { data: config } = useEmailConfig(tenantId)

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('email.section_title', 'Configuració de correu electrònic')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t(
            'email.section_description',
            "Gestiona el remitent, els dominis verificats i l'historial d'enviaments.",
          )}
        </p>
      </div>

      <QuotaCard
        tenantId={tenantId}
        rateLimitPerHour={config?.rate_limit_per_hour ?? 100}
        rateLimitPerDay={config?.rate_limit_per_day ?? 1000}
        maxRetries={config?.max_retries ?? 3}
        retentionDays={config?.retention_days ?? 90}
      />

      <Tabs defaultValue="general">
        <TabsList className="w-full justify-start">
          <TabsTrigger value="general">
            {t('email.tabs.general', 'Configuració general')}
          </TabsTrigger>
          <TabsTrigger value="templates">
            {t('email.tabs.templates', 'Plantilles')}
          </TabsTrigger>
          <TabsTrigger value="domains">
            {t('email.tabs.domains', 'Dominis')}
          </TabsTrigger>
          <TabsTrigger value="logs">
            {t('email.tabs.logs', 'Historial')}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="general" className="pt-4">
          <EmailGeneralTab tenantId={tenantId} />
        </TabsContent>
        <TabsContent value="templates" className="pt-4">
          <EmailTemplatesTab tenantId={tenantId} />
        </TabsContent>
        <TabsContent value="domains" className="pt-4">
          <EmailDomainsTab tenantId={tenantId} />
        </TabsContent>
        <TabsContent value="logs" className="pt-4">
          <EmailLogsTab tenantId={tenantId} />
        </TabsContent>
      </Tabs>
    </div>
  )
}
