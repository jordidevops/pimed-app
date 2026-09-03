export { AutomationDashboard } from './components/AutomationDashboard'
export { WorkflowList } from './components/WorkflowList'
export { WorkflowEditor } from './components/WorkflowEditor'
export { WorkflowRunDetail } from './components/WorkflowRunDetail'
export { BlueprintCatalog } from './components/BlueprintCatalog'
export { ApprovalDialog } from './components/ApprovalDialog'

export type {
  AutomationDashboard as AutomationDashboardData,
  AutomationWorkflow,
  AutomationRun,
  AutomationStepRun,
  AutomationPendingApproval,
  AutomationRunStatus,
  AutomationStepRunStatus,
  AutomationStep,
} from './api/automationService'

export {
  getAutomationDashboard,
  listWorkflows,
  listBlueprints,
  getWorkflowRuns,
  getRunDetail,
  listPendingApprovals,
  upsertWorkflow,
  deleteWorkflow,
  installBlueprint,
  resolveApproval,
  retryRun,
  cancelRun,
} from './api/automationService'
