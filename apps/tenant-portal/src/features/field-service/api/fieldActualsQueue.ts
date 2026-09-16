import { enqueueFieldOp } from '@/hooks/useFieldSync'
import { getFieldOpsAdapter } from '@/lib/field-ops-db'

export async function enqueueProjectLineActual(input: {
  tenantId: string
  projectId: string
  lineId?: string
  unit: 'h' | 'km'
  quantity: number
  dependsOn?: string[]
}): Promise<string> {
  const { adapter, isFallback } = await getFieldOpsAdapter()
  if (isFallback && !navigator.onLine) {
    throw new Error('offline_storage_not_durable')
  }
  const active = await adapter.listProjectOps(input.tenantId, input.projectId, [
    'pending',
    'syncing',
    'rejected',
    'quarantined',
  ])
  const previousForTarget = [...active].reverse().find((op) => {
    if (op.kind !== 'project_line.actual') return false
    const payload = op.payload as { line_id?: string; unit?: string }
    return input.lineId
      ? payload.line_id === input.lineId
      : !payload.line_id && payload.unit === input.unit
  })
  const id = crypto.randomUUID()
  return enqueueFieldOp({
    id,
    tenant_id: input.tenantId,
    project_id: input.projectId,
    kind: 'project_line.actual',
    status: 'pending',
    depends_on: [
      ...new Set([
        ...(input.dependsOn ?? []),
        ...(previousForTarget ? [previousForTarget.id] : []),
      ]),
    ],
    payload: {
      project_id: input.projectId,
      line_id: input.lineId,
      unit: input.unit,
      quantity: input.quantity,
    },
  })
}

export async function enqueueProjectMaterial(input: {
  tenantId: string
  projectId: string
  name: string
  quantity: number
  unit?: string
  workLogId?: string
  workLogClientOpId?: string
  dependsOn?: string[]
}): Promise<string> {
  const { isFallback } = await getFieldOpsAdapter()
  if (isFallback && !navigator.onLine) {
    throw new Error('offline_storage_not_durable')
  }
  const id = crypto.randomUUID()
  return enqueueFieldOp({
    id,
    tenant_id: input.tenantId,
    project_id: input.projectId,
    kind: 'project_material.add',
    status: 'pending',
    depends_on: input.dependsOn,
    payload: {
      project_id: input.projectId,
      name: input.name,
      quantity: input.quantity,
      unit: input.unit,
      work_log_id: input.workLogId,
      work_log_client_op_id: input.workLogClientOpId,
    },
  })
}

export async function enqueueProjectCloseOut(input: {
  tenantId: string
  projectId: string
  bypassReason?: string
}): Promise<string> {
  const { adapter, isFallback } = await getFieldOpsAdapter()
  if (isFallback && !navigator.onLine) {
    throw new Error('offline_storage_not_durable')
  }
  const active = await adapter.listProjectOps(input.tenantId, input.projectId, [
    'pending',
    'syncing',
    'rejected',
    'quarantined',
  ])
  const id = crypto.randomUUID()
  return enqueueFieldOp({
    id,
    tenant_id: input.tenantId,
    project_id: input.projectId,
    kind: 'project.close_out',
    status: 'pending',
    depends_on: active
      .filter((op) => op.kind !== 'project.close_out')
      .map((op) => op.id),
    payload: {
      project_id: input.projectId,
      bypass_reason: input.bypassReason?.trim() || undefined,
    },
  })
}
