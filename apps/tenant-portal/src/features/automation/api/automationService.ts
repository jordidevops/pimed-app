import { supabase } from '@/lib/supabase'

// ─── Types ────────────────────────────────────────────────────────────────────

export interface AutomationPendingApprovalSummary {
  id: string
  title: string
  assigned_to_role: string | null
  due_at: string | null
  workflow_run_id: string
  step_run_id: string
}

export interface AutomationRecentFailure {
  run_id: string
  workflow_id: string
  workflow_name: string
  error: string | null
  started_at: string
}

export interface AutomationRecentRun {
  run_id: string
  workflow_id: string
  workflow_name: string
  status: string
  started_at: string
}

export interface AutomationDashboard {
  runs_running: number
  runs_waiting_human: number
  runs_failed: number
  runs_completed_today: number
  pending_approvals: AutomationPendingApprovalSummary[]
  recent_failures: AutomationRecentFailure[]
  recent_runs: AutomationRecentRun[]
}

export interface AutomationWorkflow {
  id: string
  name: string
  description: string | null
  trigger_event: string
  trigger_filters: Record<string, unknown> | null
  steps: AutomationStep[]
  is_active: boolean
  is_blueprint: boolean
  source_blueprint_id: string | null
  version: number
  tenant_id: string | null
  created_at: string
  updated_at: string
}

export interface AutomationStep {
  id: string
  type: string
  name: string
  config: Record<string, unknown>
  on_error?: 'abort' | 'continue' | 'retry'
}

export type AutomationRunStatus =
  | 'RUNNING'
  | 'WAITING_HUMAN'
  | 'COMPLETED'
  | 'FAILED'
  | 'CANCELLED'

export interface AutomationRun {
  id: string
  workflow_id: string
  workflow_name?: string
  status: AutomationRunStatus
  trigger_event: string
  trigger_entity_type: string | null
  trigger_entity_id: string | null
  context: Record<string, unknown> | null
  current_step_id: string | null
  error: string | null
  started_at: string
  completed_at: string | null
  created_at: string
}

export type AutomationStepRunStatus =
  | 'PENDING'
  | 'RUNNING'
  | 'COMPLETED'
  | 'FAILED'
  | 'SKIPPED'
  | 'WAITING_HUMAN'

export interface AutomationStepRun {
  id: string
  workflow_run_id: string
  step_id: string
  step_name: string
  step_type: string
  status: AutomationStepRunStatus
  input: Record<string, unknown> | null
  output: Record<string, unknown> | null
  error: string | null
  attempt_number: number
  started_at: string | null
  completed_at: string | null
}

export interface AutomationPendingApproval {
  id: string
  step_run_id: string
  workflow_run_id: string
  tenant_id: string
  assigned_to_user_id: string | null
  assigned_to_role: string | null
  context_preview: Record<string, unknown> | null
  title: string
  status: 'PENDING' | 'APPROVED' | 'REJECTED' | 'REASSIGNED'
  due_at: string | null
  created_at: string
}

// ─── API Functions ────────────────────────────────────────────────────────────

export async function getAutomationDashboard(): Promise<AutomationDashboard> {
  const { data, error } = await supabase.rpc('get_automation_dashboard', {})
  if (error) throw error
  return data as AutomationDashboard
}

export async function listWorkflows(): Promise<AutomationWorkflow[]> {
  const { data, error } = await supabase
    .schema('api')
    .from('automation_workflows')
    .select('*')
    .eq('is_blueprint', false)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as AutomationWorkflow[]
}

export async function listBlueprints(): Promise<AutomationWorkflow[]> {
  const { data, error } = await supabase
    .schema('api')
    .from('automation_workflows')
    .select('*')
    .eq('is_blueprint', true)
    .order('name', { ascending: true })
  if (error) throw error
  return (data ?? []) as AutomationWorkflow[]
}

export async function getWorkflowRuns(
  workflowId?: string,
  limit = 50,
): Promise<AutomationRun[]> {
  let query = supabase
    .schema('api')
    .from('automation_runs')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(limit)

  if (workflowId) {
    query = query.eq('workflow_id', workflowId)
  }

  const { data, error } = await query
  if (error) throw error
  return (data ?? []) as AutomationRun[]
}

export async function getRunDetail(
  runId: string,
): Promise<{ run: AutomationRun; stepRuns: AutomationStepRun[] }> {
  const [runResult, stepsResult] = await Promise.all([
    supabase.schema('api').from('automation_runs').select('*').eq('id', runId).single(),
    supabase
      .schema('api')
      .from('automation_step_runs')
      .select('*')
      .eq('workflow_run_id', runId)
      .order('started_at', { ascending: true }),
  ])

  if (runResult.error) throw runResult.error
  if (stepsResult.error) throw stepsResult.error

  return {
    run: runResult.data as AutomationRun,
    stepRuns: (stepsResult.data ?? []) as AutomationStepRun[],
  }
}

export async function listPendingApprovals(): Promise<AutomationPendingApproval[]> {
  const { data, error } = await supabase
    .schema('api')
    .from('automation_pending_approvals')
    .select('*')
    .eq('status', 'PENDING')
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as AutomationPendingApproval[]
}

export async function upsertWorkflow(
  params: Partial<AutomationWorkflow> & { name: string; trigger_event: string; steps: AutomationStep[] },
): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_automation_workflow', {
    p_id: params.id ?? null,
    p_name: params.name,
    p_description: params.description ?? null,
    p_trigger_event: params.trigger_event,
    p_trigger_filters: params.trigger_filters ?? null,
    p_steps: params.steps,
    p_is_active: params.is_active ?? true,
    p_site_id: null,
  })
  if (error) throw error
  return data as string
}

export async function deleteWorkflow(id: string): Promise<void> {
  const { error } = await supabase.rpc('delete_automation_workflow', { p_id: id })
  if (error) throw error
}

export async function installBlueprint(
  blueprintId: string,
  config?: Record<string, unknown>,
): Promise<string> {
  const { data, error } = await supabase.rpc('install_blueprint', {
    p_blueprint_id: blueprintId,
    p_config: config ?? {},
  })
  if (error) throw error
  return data as string
}

export async function resolveApproval(
  approvalId: string,
  resolution: 'approved' | 'rejected' | 'reassigned',
  comment?: string,
  reassignTo?: string,
): Promise<void> {
  const { error } = await supabase.rpc('resolve_automation_approval', {
    p_approval_id: approvalId,
    p_resolution: resolution,
    p_comment: comment ?? null,
    p_reassign_to_user_id: reassignTo ?? null,
  })
  if (error) throw error
}

export async function retryRun(runId: string): Promise<void> {
  const { error } = await supabase.rpc('retry_automation_run', { p_run_id: runId })
  if (error) throw error
}

export async function cancelRun(runId: string): Promise<void> {
  const { error } = await supabase.rpc('cancel_automation_run', { p_run_id: runId })
  if (error) throw error
}
