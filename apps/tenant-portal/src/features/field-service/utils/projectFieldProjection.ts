import type {
  LocalFieldOp,
  ProjectLineActualPayload,
  ProjectMaterialAddPayload,
} from '../../../lib/field-ops-db'

export type LocalCloseOutState =
  | 'none'
  | 'local_pending'
  | 'action_required'
  | 'synced'

export function projectFieldProjection(ops: LocalFieldOp[]) {
  const lineActuals = new Map<string, { op: LocalFieldOp; payload: ProjectLineActualPayload }>()
  const materials: Array<{ op: LocalFieldOp; payload: ProjectMaterialAddPayload }> = []
  let closeOp: LocalFieldOp | null = null

  for (const op of ops) {
    if (op.kind === 'project_line.actual' && op.status !== 'synced') {
      const payload = op.payload as ProjectLineActualPayload
      const key = payload.line_id ?? `new:${payload.unit}`
      lineActuals.set(key, { op, payload })
    } else if (op.kind === 'project_material.add' && op.status !== 'synced') {
      materials.push({ op, payload: op.payload as ProjectMaterialAddPayload })
    } else if (op.kind === 'project.close_out') {
      closeOp = op
    }
  }

  const dependencyFailure = closeOp
    ? ops.find(
        (op) =>
          (closeOp?.depends_on ?? []).includes(op.id) &&
          (op.status === 'quarantined' || op.status === 'rejected'),
      ) ?? null
    : null
  const missingDependencyId = closeOp?.depends_on?.find(
    (id) => !ops.some((op) => op.id === id),
  ) ?? null
  const closeState: LocalCloseOutState =
    closeOp?.status === 'quarantined' ||
    closeOp?.status === 'rejected' ||
    !!dependencyFailure ||
    !!missingDependencyId
      ? 'action_required'
      : closeOp?.status === 'synced'
        ? 'synced'
        : closeOp
        ? 'local_pending'
        : 'none'

  return {
    lineActuals,
    materials,
    closeOp,
    dependencyFailure,
    missingDependencyId,
    closeState,
    dependencyIds: ops
      .filter((op) => op.kind !== 'project.close_out' && op.status !== 'synced')
      .map((op) => op.id),
  }
}
