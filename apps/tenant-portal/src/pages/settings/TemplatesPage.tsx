import { useTranslation } from 'react-i18next'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { SigningRoleDefaultsSection } from './SigningRoleDefaultsSection'
import { ContentBlocksSection } from './ContentBlocksSection'

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

      <Tabs defaultValue="roles">
        <TabsList>
          <TabsTrigger value="roles">
            {t('templates.tabRoles', 'Rols per defecte')}
          </TabsTrigger>
          <TabsTrigger value="blocks">
            {t('templates.tabBlocks', 'Blocs de contingut')}
          </TabsTrigger>
        </TabsList>
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
