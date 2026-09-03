// =============================================================================
// Automation Engine — tipus compartits
// =============================================================================

// -----------------------------------------------------------------------------
// Status enums
// -----------------------------------------------------------------------------

export type AutomationRunStatus =
  | "PENDING"
  | "RUNNING"
  | "WAITING_HUMAN"
  | "WAITING_TIMER"
  | "COMPLETED"
  | "FAILED"
  | "CANCELLED";

export type AutomationStepStatus =
  | "PENDING"
  | "RUNNING"
  | "COMPLETED"
  | "FAILED"
  | "SKIPPED"
  | "WAITING_HUMAN"
  | "WAITING_TIMER";

export type AutomationApprovalStatus =
  | "PENDING"
  | "APPROVED"
  | "REJECTED"
  | "EXPIRED"
  | "CANCELLED";

// -----------------------------------------------------------------------------
// Step types
// -----------------------------------------------------------------------------

export type StepType =
  | "SEND_EMAIL"
  | "SEND_NOTIFICATION"
  | "CREATE_TASK"
  | "CREATE_CALENDAR_EVENT"
  | "GENERATE_DOCUMENT"
  | "SEND_FOR_SIGNING"
  | "HUMAN_APPROVAL"
  | "CONDITION"
  | "UPDATE_FIELD"
  | "WAIT";

// -----------------------------------------------------------------------------
// Step definition (dins automation_workflows.steps JSONB)
// -----------------------------------------------------------------------------

export interface StepDefinition {
  /** Identificador únic dins del workflow (no UUID, p.ex. "step_1") */
  id: string;
  name: string;
  type: StepType;
  config: Record<string, unknown>;
  /** step_id destí en cas d'èxit; 'END_OK' o absent → fi exitosa */
  on_success?: string;
  /** step_id destí en cas de fallada; 'END_FAIL' o absent → fi amb error */
  on_failure?: string;
  /** Nombre màxim de reintents automàtics. Per defecte 3 */
  retry_max?: number;
  /** Temps màxim d'execució en minuts. Absent → sense límit */
  timeout_minutes?: number;
}

// -----------------------------------------------------------------------------
// Workflow context — snapshot de l'entitat que ha disparat el trigger
// -----------------------------------------------------------------------------

export interface WorkflowContext {
  trigger: {
    event: string;
    entity_type: string | null;
    entity_id: string | null;
    actor_user_id: string | null;
    site_id: string | null;
    timestamp: string;
    payload: Record<string, unknown>;
  };
  tenant: {
    id: string;
    name: string;
    slug?: string;
  };
  site?: {
    id: string;
    name: string;
  } | null;
  /** Snapshot de l'entitat principal (empleat, document, etc.) */
  entity?: Record<string, unknown>;
  /** Document generat o referenciat pel workflow */
  document?: Record<string, unknown>;
  /** Rols resolts (signer, manager, etc.) per a emails */
  roles?: Record<string, Record<string, unknown>>;
  /** Variables de plantilla addicionals */
  variables?: Record<string, unknown>;
  /** Outputs dels steps anteriors indexats per step_id */
  steps: Record<string, Record<string, unknown>>;
  /**
   * Informació d'execució injectada per process-automation-queue.
   * Disponible per als handlers que necessiten el step_run_id (ex: HUMAN_APPROVAL).
   */
  runtime?: {
    step_run_id: string;
    workflow_run_id: string;
    step_id: string;
    tenant_id: string;
  };
}

// -----------------------------------------------------------------------------
// Missatge a workflow_trigger_queue
// -----------------------------------------------------------------------------

export interface WorkflowTriggerPayload {
  task: "process_workflow_trigger";
  tenant_id: string;
  /** Format: 'wft:<audit_log_id>' per garantir idempotència */
  idempotency_key: string;
  event_type: string;
  entity_type: string | null;
  entity_id: string | null;
  actor_user_id: string | null;
  site_id: string | null;
  payload: Record<string, unknown>;
  audit_log_id: string;
}

// -----------------------------------------------------------------------------
// Missatge a automation_queue
// -----------------------------------------------------------------------------

export interface AutomationStepPayload {
  task: "execute_step";
  tenant_id: string;
  /** Format: 'step:<step_run_id>:<attempt_number>' */
  idempotency_key: string;
  workflow_run_id: string;
  step_run_id: string;
  step_id: string;
  step_type: StepType;
  attempt_number: number;
}

// -----------------------------------------------------------------------------
// Resultat retornat per un handler d'step
// -----------------------------------------------------------------------------

export interface StepHandlerResult {
  success: boolean;
  output?: Record<string, unknown>;
  error?: string;
  /** Si true, el workflow queda en WAITING_HUMAN fins aprovació manual */
  waitingHuman?: boolean;
  /** Si true, el workflow queda en WAITING_TIMER fins event extern */
  waitingTimer?: boolean;
  /** step_id al qual saltar (sobreescriu on_success / on_failure) */
  nextStepId?: string;
}
