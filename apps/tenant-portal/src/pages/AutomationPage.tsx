import { useState } from 'react'
import { Zap } from 'lucide-react'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { AutomationDashboard } from '../features/automation/components/AutomationDashboard'
import { WorkflowList } from '../features/automation/components/WorkflowList'
import { WorkflowEditor } from '../features/automation/components/WorkflowEditor'
import { WorkflowRunDetail } from '../features/automation/components/WorkflowRunDetail'
import { BlueprintCatalog } from '../features/automation/components/BlueprintCatalog'
import type { AutomationWorkflow } from '../features/automation/api/automationService'

type View =
  | { type: 'tabs'; activeTab: string }
  | { type: 'run-detail'; runId: string }
  | { type: 'workflow-editor'; workflow?: AutomationWorkflow }

export function AutomationPage() {
  const [view, setView] = useState<View>({ type: 'tabs', activeTab: 'dashboard' })

  function goToDashboard() {
    setView({ type: 'tabs', activeTab: 'dashboard' })
  }

  function goToWorkflows() {
    setView({ type: 'tabs', activeTab: 'workflows' })
  }

  function openRunDetail(runId: string) {
    setView({ type: 'run-detail', runId })
  }

  function openEditor(workflow?: AutomationWorkflow) {
    setView({ type: 'workflow-editor', workflow })
  }

  if (view.type === 'run-detail') {
    return (
      <div className="max-w-4xl mx-auto px-4 py-8">
        <WorkflowRunDetail runId={view.runId} onBack={goToDashboard} />
      </div>
    )
  }

  if (view.type === 'workflow-editor') {
    return (
      <div className="max-w-3xl mx-auto px-4 py-8">
        <div className="mb-6">
          <div className="flex items-center gap-2 mb-1">
            <Zap className="h-5 w-5 text-primary" />
            <h1 className="text-2xl font-bold">
              {view.workflow ? 'Editar workflow' : 'Nou workflow'}
            </h1>
          </div>
          <p className="text-sm text-muted-foreground">
            {view.workflow
              ? `Editant "${view.workflow.name}"`
              : 'Crea un nou workflow d\'automatització'}
          </p>
        </div>
        <div className="rounded-2xl border bg-card p-6">
          <WorkflowEditor
            workflow={view.workflow}
            onSaved={goToWorkflows}
            onCancel={goToWorkflows}
          />
        </div>
      </div>
    )
  }

  // Default tab view
  const activeTab = view.activeTab

  return (
    <div className="max-w-5xl mx-auto px-4 py-8">
      {/* Page header */}
      <div className="mb-8 flex items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <Zap className="h-6 w-6 text-primary" />
            <h1 className="text-2xl font-bold">Centre d'automatitzacions</h1>
          </div>
          <p className="text-sm text-muted-foreground">
            Gestiona els workflows automàtics del teu espai de treball.
          </p>
        </div>
      </div>

      <Tabs
        value={activeTab}
        onValueChange={(tab) => setView({ type: 'tabs', activeTab: tab })}
      >
        <TabsList className="mb-6">
          <TabsTrigger value="dashboard">Tauler</TabsTrigger>
          <TabsTrigger value="workflows">Workflows</TabsTrigger>
          <TabsTrigger value="blueprints">Blueprints</TabsTrigger>
        </TabsList>

        <TabsContent value="dashboard">
          <AutomationDashboard onViewRunDetail={openRunDetail} />
        </TabsContent>

        <TabsContent value="workflows">
          <WorkflowList
            onEdit={(wf) => openEditor(wf)}
            onCreate={() => openEditor(undefined)}
          />
        </TabsContent>

        <TabsContent value="blueprints">
          <BlueprintCatalog />
        </TabsContent>
      </Tabs>
    </div>
  )
}
