import { supabase } from '@/lib/supabase'
import { getCalculatorDefinition } from './calculatorService'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'

export type CommercialQuickFlowStatus = 'draft' | 'active' | 'archived'

export type CommercialQuickFlowRow = {
  id: string
  tenant_id: string
  name: string
  description: string | null
  status: CommercialQuickFlowStatus
  calculator_definition_id: string | null
  pricing_template_id: string | null
  quote_template_id: string
  formalization_mode: FormalizationMode
  agreement_template_id: string | null
  sort_order: number
  created_at: string
  updated_at: string
}

export type CommercialQuickFlowInput = {
  name: string
  description?: string | null
  status?: CommercialQuickFlowStatus
  calculatorDefinitionId?: string | null
  pricingTemplateId?: string | null
  quoteTemplateId: string
  formalizationMode: FormalizationMode
  agreementTemplateId?: string | null
  sortOrder?: number
}

function assertActiveSourceShape(
  input: CommercialQuickFlowInput,
  status: CommercialQuickFlowStatus,
) {
  if (status !== 'active') return
  const hasCalc = !!input.calculatorDefinitionId
  const hasHabit = !!input.pricingTemplateId
  if (hasCalc === hasHabit) {
    throw new Error('flow_source_required')
  }
  if (input.formalizationMode === 'separate_agreement' && !input.agreementTemplateId) {
    throw new Error('flow_agreement_template_required')
  }
}

async function assertActiveSourceHealthy(
  input: CommercialQuickFlowInput,
  status: CommercialQuickFlowStatus,
) {
  assertActiveSourceShape(input, status)
  if (status !== 'active') return
  if (input.calculatorDefinitionId) {
    const calc = await getCalculatorDefinition(input.calculatorDefinitionId)
    if (calc.status !== 'active' || !calc.published_version_id) {
      throw new Error('flow_source_inactive')
    }
  }
  if (input.pricingTemplateId) {
    const { data, error } = await supabase
      .from('pricing_templates' as never)
      .select('id, is_active')
      .eq('id', input.pricingTemplateId)
      .maybeSingle()
    if (error) throw error
    const row = data as { id: string; is_active: boolean } | null
    if (!row || row.is_active === false) {
      throw new Error('flow_source_inactive')
    }
  }
}

export async function listCommercialQuickFlows(opts?: {
  status?: CommercialQuickFlowStatus | 'all'
}): Promise<CommercialQuickFlowRow[]> {
  let q = supabase
    .from('commercial_quick_flows' as never)
    .select('*')
    .order('sort_order', { ascending: true })
    .order('name', { ascending: true })
  if (opts?.status && opts.status !== 'all') {
    q = q.eq('status', opts.status)
  }
  const { data, error } = await q
  if (error) throw error
  return (data ?? []) as CommercialQuickFlowRow[]
}

export async function listActiveCommercialQuickFlows(): Promise<CommercialQuickFlowRow[]> {
  return listCommercialQuickFlows({ status: 'active' })
}

export async function createCommercialQuickFlow(
  tenantId: string,
  input: CommercialQuickFlowInput,
): Promise<CommercialQuickFlowRow> {
  const status = input.status ?? 'draft'
  await assertActiveSourceHealthy(input, status)
  const { data, error } = await supabase
    .from('commercial_quick_flows' as never)
    .insert({
      tenant_id: tenantId,
      name: input.name.trim(),
      description: input.description?.trim() || null,
      status,
      calculator_definition_id: input.calculatorDefinitionId ?? null,
      pricing_template_id: input.pricingTemplateId ?? null,
      quote_template_id: input.quoteTemplateId,
      formalization_mode: input.formalizationMode,
      agreement_template_id: input.agreementTemplateId ?? null,
      sort_order: input.sortOrder ?? 0,
    } as never)
    .select('*')
    .single()
  if (error) throw error
  return data as CommercialQuickFlowRow
}

export async function updateCommercialQuickFlow(
  id: string,
  input: CommercialQuickFlowInput,
): Promise<CommercialQuickFlowRow> {
  const status = input.status ?? 'draft'
  await assertActiveSourceHealthy(input, status)
  const { data, error } = await supabase
    .from('commercial_quick_flows' as never)
    .update({
      name: input.name.trim(),
      description: input.description?.trim() || null,
      status,
      calculator_definition_id: input.calculatorDefinitionId ?? null,
      pricing_template_id: input.pricingTemplateId ?? null,
      quote_template_id: input.quoteTemplateId,
      formalization_mode: input.formalizationMode,
      agreement_template_id: input.agreementTemplateId ?? null,
      sort_order: input.sortOrder ?? 0,
    } as never)
    .eq('id', id)
    .select('*')
    .single()
  if (error) throw error
  return data as CommercialQuickFlowRow
}

export async function setCommercialQuickFlowStatus(
  id: string,
  status: CommercialQuickFlowStatus,
): Promise<void> {
  if (status === 'active') {
    const { data: row, error: loadErr } = await supabase
      .from('commercial_quick_flows' as never)
      .select('*')
      .eq('id', id)
      .single()
    if (loadErr) throw loadErr
    const current = row as CommercialQuickFlowRow
    await assertActiveSourceHealthy(
      {
        name: current.name,
        calculatorDefinitionId: current.calculator_definition_id,
        pricingTemplateId: current.pricing_template_id,
        quoteTemplateId: current.quote_template_id,
        formalizationMode: current.formalization_mode,
        agreementTemplateId: current.agreement_template_id,
      },
      'active',
    )
  }
  const { error } = await supabase
    .from('commercial_quick_flows' as never)
    .update({ status } as never)
    .eq('id', id)
  if (error) throw error
}
