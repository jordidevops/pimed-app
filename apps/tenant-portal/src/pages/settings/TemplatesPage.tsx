import { useTranslation } from 'react-i18next'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { SigningRoleDefaultsSection } from './SigningRoleDefaultsSection'
import { ContentBlocksSection } from './ContentBlocksSection'
import { CommercialDocumentTemplatesSection, CommercialDeviationThresholdSection } from '@/features/commercial/components/CommercialDocumentTemplatesSection'

export function TemplatesPage() {
  const { t } = useTranslation('settings')

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('templates.page_title', 'Plantilles de documents')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('templates.page_description', 'Configura preferències de plantilles i rols per defecte per agilitzar la generació de documents.')}
        </p>
      </div>

      <Tabs defaultValue="commercial">
        <TabsList>
          <TabsTrigger value="commercial">
            {t('templates.tabCommercial', 'Comercial')}
          </TabsTrigger>
          <TabsTrigger value="roles">
            {t('templates.tabRoles', 'Rols per defecte')}
          </TabsTrigger>
          <TabsTrigger value="blocks">
            {t('templates.tabBlocks', 'Blocs de contingut')}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="commercial" className="mt-4 space-y-4">
          <CommercialDocumentTemplatesSection />
          <CommercialDeviationThresholdSection />
        </TabsContent>
        <TabsContent value="roles" className="mt-4">
          <SigningRoleDefaultsSection />
        </TabsContent>
        <TabsContent value="blocks" className="mt-4">
          <ContentBlocksSection />
        </TabsContent>
      </Tabs>
    </div>
  )
}
