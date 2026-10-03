import { supabase } from '@/lib/supabase'

export type ProjectExpensePaidBy = 'company' | 'employee'

export type ProjectExpense = {
  id: string
  tenant_id: string
  project_id: string
  work_log_id: string | null
  amount_cents: number
  currency: string
  description: string
  category: string | null
  receipt_document_id: string | null
  is_billable: boolean
  paid_by: ProjectExpensePaidBy
  created_by: string
  created_at: string
}

export async function getProjectExpenses(projectId: string): Promise<ProjectExpense[]> {
  const { data, error } = await supabase
    .from('project_expenses' as never)
    .select('*')
    .eq('project_id', projectId)
    .order('created_at', { ascending: false })
    .limit(100)
  if (error) throw error
  return (data ?? []) as ProjectExpense[]
}

export type AddProjectExpenseInput = {
  project_id: string
  description: string
  amount_cents: number
  is_billable?: boolean
  paid_by?: ProjectExpensePaidBy
  category?: string | null
  work_log_id?: string | null
}

export async function addProjectExpense(input: AddProjectExpenseInput): Promise<string> {
  const { data, error } = await supabase.rpc('add_project_expense' as never, {
    p_project_id: input.project_id,
    p_description: input.description,
    p_amount_cents: input.amount_cents,
    p_is_billable: input.is_billable ?? false,
    p_paid_by: input.paid_by ?? 'company',
    p_category: input.category ?? null,
    p_work_log_id: input.work_log_id ?? null,
  } as never)
  if (error) throw error
  return String(data)
}
