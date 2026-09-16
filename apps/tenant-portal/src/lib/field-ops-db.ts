import Dexie, { type Table } from 'dexie'

// ---------------------------------------------------------------------------
// Tipus
// ---------------------------------------------------------------------------

export type FieldOpKind =
  | 'worklog.start'
  | 'worklog.stop'
  | 'project_line.actual'
  | 'project_material.add'
  | 'project.close_out'

export type FieldOpStatus =
  | 'pending'
  | 'syncing'
  | 'synced'
  | 'rejected'
  | 'quarantined'

export interface GeoPayload {
  latitude: number
  longitude: number
  accuracy_meters?: number
  timestamp?: string
}

export interface WorklogStartPayload {
  project_id: string
  project_name: string
  task_id?: string
  task_name?: string
  occurred_at: string
  geo?: GeoPayload
  location_permission?: string
  notes?: string
}

export interface WorklogStopPayload {
  /** id de l'operació worklog.start corresponent (≠ id d'aquesta op!) */
  client_op_id: string
  /** server_id del start si ja estava sincronitzat quan es va crear el stop */
  work_log_id?: string
  occurred_at: string
  geo?: GeoPayload
  location_permission?: string
  close_task?: boolean
  notes?: string
}

export interface ProjectLineActualPayload {
  project_id: string
  line_id?: string
  unit: 'h' | 'km'
  quantity: number
}

export interface ProjectMaterialAddPayload {
  project_id: string
  name: string
  quantity: number
  unit?: string
  work_log_id?: string
  work_log_client_op_id?: string
}

export interface ProjectCloseOutPayload {
  project_id: string
  bypass_reason?: string
}

export type FieldOpPayload =
  | WorklogStartPayload
  | WorklogStopPayload
  | ProjectLineActualPayload
  | ProjectMaterialAddPayload
  | ProjectCloseOutPayload

export interface LocalFieldOp {
  /** UUID únic d'aquesta operació. S'envia com a v_op.id al batch. */
  id: string
  /** Tenant al qual pertany. Imprescindible per aïllament multi-tenant. */
  tenant_id: string
  /** Projecte afectat; duplicat del payload per poder consultar/ordenar a Dexie. */
  project_id?: string
  kind: FieldOpKind
  status: FieldOpStatus
  /** ISO8601 — usada per ordenar el batch (start SEMPRE < stop del mateix log) */
  created_at: string
  /** work_log_id retornat pel servidor, guardat post-sync */
  server_id?: string
  /** Operacions locals que han d'estar synced o purgades abans d'enviar aquesta. */
  depends_on?: string[]
  /** Marca per recuperar operacions encallades si la pestanya mor durant el drain. */
  sync_started_at?: string
  retry_count: number
  last_error?: string
  /**
   * ISO8601 — quan pot tornar a entrar al batch. NULL = elegible immediatament.
   * Calculat amb backoff exponencial + jitter per evitar thundering herd.
   */
  next_retry_at?: string
  payload: FieldOpPayload
}

export interface SyncState {
  id: 'singleton'
  lastSyncAt: string | null
  isSyncing: boolean
  consecutiveErrors: number
}

// ---------------------------------------------------------------------------
// Jitter per backoff exponencial (evita thundering herd en retry massiu)
// ---------------------------------------------------------------------------

/**
 * Calcula el delay de retry amb backoff exponencial i jitter aleatori.
 * Base duplica per cada reintent (màx 5 min) + fins a 5 s aleatòris.
 * Exemple: retry_count=0 → ~30 s, retry_count=2 → ~2 min, retry_count=4+ → ~5 min.
 */
export function calcNextRetryAt(retryCount: number): string {
  const baseMs = Math.min(30_000 * Math.pow(2, retryCount), 300_000)
  const jitterMs = Math.floor(Math.random() * 5_000)
  return new Date(Date.now() + baseMs + jitterMs).toISOString()
}

export function isFieldOpEligible(
  op: LocalFieldOp,
  byId: ReadonlyMap<string, LocalFieldOp>,
  nowIso: string,
  mode: 'non_close' | 'close' | 'all' = 'all',
): boolean {
  if (op.status !== 'pending') return false
  if (op.next_retry_at != null && op.next_retry_at > nowIso) return false
  if (mode === 'non_close' && op.kind === 'project.close_out') return false
  if (mode === 'close' && op.kind !== 'project.close_out') return false
  return (op.depends_on ?? []).every((id) => {
    const dependency = byId.get(id)
    return dependency?.status === 'synced'
  })
}

export function isStaleSyncingOp(
  op: LocalFieldOp,
  olderThanIso: string,
): boolean {
  return (
    op.status === 'syncing' &&
    (!op.sync_started_at || op.sync_started_at <= olderThanIso)
  )
}

function normalizePayloadForManualRetry(op: LocalFieldOp): FieldOpPayload {
  if (op.kind !== 'worklog.stop') return op.payload

  const stopPayload = op.payload as WorklogStopPayload
  // Compatibilitat amb dades antigues: alguns stops locals desaven
  // work_log_id amb el mateix valor que client_op_id (id local, no server id).
  if (stopPayload.work_log_id && stopPayload.client_op_id && stopPayload.work_log_id === stopPayload.client_op_id) {
    return {
      ...stopPayload,
      work_log_id: undefined,
    }
  }
  return stopPayload
}

// ---------------------------------------------------------------------------
// Adaptador comú (interfície que comparteixen Dexie i el fallback in-memory)
// ---------------------------------------------------------------------------

export interface FieldOpsAdapter {
  enqueueOp(op: LocalFieldOp): Promise<void>
  nextPendingBatch(
    tenantId: string,
    size?: number,
    mode?: 'non_close' | 'close' | 'all',
    projectId?: string,
  ): Promise<LocalFieldOp[]>
  markSyncing(ids: string[]): Promise<void>
  markSynced(id: string, serverId?: string): Promise<void>
  markRetryable(id: string, msg: string): Promise<void>
  markQuarantined(id: string, msg: string): Promise<void>
  recoverStaleSyncing(tenantId: string, olderThanIso: string): Promise<number>
  listProjectOps(
    tenantId: string,
    projectId: string,
    statuses?: FieldOpStatus[],
  ): Promise<LocalFieldOp[]>
  removeOp(id: string): Promise<void>
  purgeSynced(tenantId: string, olderThanIso: string): Promise<number>
  getSyncState(): Promise<SyncState>
  updateSyncState(patch: Partial<Omit<SyncState, 'id'>>): Promise<void>
  countPending(tenantId: string): Promise<number>
  /** Comptar operacions per estat (per exposar rejected/quarantined al hook). */
  countByStatus(tenantId: string, status: FieldOpStatus): Promise<number>
  /** Llistar operacions per estat (per retry massiu). */
  listByStatus(tenantId: string, status: FieldOpStatus): Promise<LocalFieldOp[]>
  /** Elimina operacions d'un estat concret (neteja manual d'errors permanents). */
  removeByStatus(tenantId: string, status: FieldOpStatus): Promise<number>
  /**
   * Torna a encuar una operació rejected o quarantined:
   * posa status → pending, next_retry_at = now() (elegible al pròxim cicle de 30s).
   * NO dispara drain immediatament — evita thundering herd.
   */
  requeueForRetry(id: string): Promise<void>
}

// ---------------------------------------------------------------------------
// Implementació Dexie
// ---------------------------------------------------------------------------

class FieldOpsDatabase extends Dexie {
  operations!: Table<LocalFieldOp, string>
  sync_state!: Table<SyncState, string>

  constructor() {
    super('field_ops_v1')
    // v1: schema original (sense next_retry_at)
    this.version(1).stores({
      operations: 'id, status, created_at, [tenant_id+status+created_at]',
      sync_state: 'id',
    })
    // v2: afegeix next_retry_at per backoff. Dexie migra automàticament (ADD INDEX).
    this.version(2).stores({
      operations: 'id, status, created_at, next_retry_at, [tenant_id+status+created_at]',
      sync_state: 'id',
    })
    this.version(3).stores({
      operations:
        'id, tenant_id, project_id, status, created_at, next_retry_at, sync_started_at, [tenant_id+status+created_at], [tenant_id+project_id+status+created_at]',
      sync_state: 'id',
    })
  }
}

const MAX_PENDING = 500

class DexieAdapter implements FieldOpsAdapter {
  private db: FieldOpsDatabase

  constructor(db: FieldOpsDatabase) {
    this.db = db
  }

  async enqueueOp(op: LocalFieldOp): Promise<void> {
    const pending = await this.countPending(op.tenant_id)
    if (pending >= MAX_PENDING) {
      throw new Error(
        `Límit d'operacions pendents (${MAX_PENDING}) superat per al tenant ${op.tenant_id}`,
      )
    }
    await this.db.operations.add(op)
  }

  async nextPendingBatch(
    tenantId: string,
    size = 20,
    mode: 'non_close' | 'close' | 'all' = 'all',
    projectId?: string,
  ): Promise<LocalFieldOp[]> {
    const now = new Date().toISOString()
    const pending = await this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, 'pending', Dexie.minKey], [tenantId, 'pending', Dexie.maxKey])
      .sortBy('created_at')
    const tenantOps = await this.db.operations
      .where('tenant_id')
      .equals(tenantId)
      .toArray()
    const byId = new Map(tenantOps.map((op) => [op.id, op]))
    return pending
      .filter((op) => !projectId || op.project_id === projectId)
      .filter((op) => isFieldOpEligible(op, byId, now, mode))
      .slice(0, size)
  }

  async markSyncing(ids: string[]): Promise<void> {
    const now = new Date().toISOString()
    await this.db.operations
      .where('id')
      .anyOf(ids)
      .modify({ status: 'syncing', sync_started_at: now })
  }

  async markSynced(id: string, serverId?: string): Promise<void> {
    await this.db.operations.update(id, {
      status: 'synced',
      sync_started_at: undefined,
      next_retry_at: undefined,
      last_error: undefined,
      ...(serverId ? { server_id: serverId } : {}),
    })
  }

  async markRetryable(id: string, msg: string): Promise<void> {
    const op = await this.db.operations.get(id)
    if (!op) return
    const newRetryCount = op.retry_count + 1
    await this.db.operations.update(id, {
      status: 'pending',
      retry_count: newRetryCount,
      last_error: msg,
      next_retry_at: calcNextRetryAt(newRetryCount),
      sync_started_at: undefined,
    })
  }

  async markQuarantined(id: string, msg: string): Promise<void> {
    await this.db.operations.update(id, {
      status: 'quarantined',
      last_error: msg,
      sync_started_at: undefined,
    })
  }

  async recoverStaleSyncing(tenantId: string, olderThanIso: string): Promise<number> {
    const rows = await this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, 'syncing', Dexie.minKey], [tenantId, 'syncing', Dexie.maxKey])
      .toArray()
    const ids = rows
      .filter((op) => isStaleSyncingOp(op, olderThanIso))
      .map((op) => op.id)
    if (ids.length > 0) {
      await this.db.operations.where('id').anyOf(ids).modify({
        status: 'pending',
        sync_started_at: undefined,
        next_retry_at: new Date().toISOString(),
      })
    }
    return ids.length
  }

  async listProjectOps(
    tenantId: string,
    projectId: string,
    statuses?: FieldOpStatus[],
  ): Promise<LocalFieldOp[]> {
    const rows = await this.db.operations
      .where('project_id')
      .equals(projectId)
      .filter((op) => op.tenant_id === tenantId)
      .toArray()
    return rows
      .filter((op) => !statuses || statuses.includes(op.status))
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
  }

  async removeOp(id: string): Promise<void> {
    const target = await this.db.operations.get(id)
    if (target) {
      const dependants = await this.db.operations
        .where('tenant_id')
        .equals(target.tenant_id)
        .filter(
          (op) =>
            op.status !== 'synced' &&
            (op.depends_on ?? []).includes(id),
        )
        .count()
      if (dependants > 0) throw new Error('field_op_is_dependency')
    }
    await this.db.operations.delete(id)
  }

  async purgeSynced(tenantId: string, olderThanIso: string): Promise<number> {
    const allRows = await this.db.operations
      .where('tenant_id')
      .equals(tenantId)
      .toArray()
    const referencedIds = new Set(
      allRows
        .filter((op) => op.status !== 'synced')
        .flatMap((op) => op.depends_on ?? []),
    )
    const ids = allRows
      .filter(
        (op) =>
          op.status === 'synced' &&
          op.created_at < olderThanIso &&
          !referencedIds.has(op.id),
      )
      .map((op) => op.id)
    if (ids.length > 0) await this.db.operations.bulkDelete(ids)
    return ids.length
  }

  async countByStatus(tenantId: string, status: FieldOpStatus): Promise<number> {
    return this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, status, Dexie.minKey], [tenantId, status, Dexie.maxKey])
      .count()
  }

  async listByStatus(tenantId: string, status: FieldOpStatus): Promise<LocalFieldOp[]> {
    return this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, status, Dexie.minKey], [tenantId, status, Dexie.maxKey])
      .sortBy('created_at')
  }

  async removeByStatus(tenantId: string, status: FieldOpStatus): Promise<number> {
    const allRows = await this.db.operations
      .where('tenant_id')
      .equals(tenantId)
      .toArray()
    const referencedIds = new Set(
      allRows
        .filter((op) => op.status !== 'synced')
        .flatMap((op) => op.depends_on ?? []),
    )
    const keys = allRows
      .filter((op) => op.status === status && !referencedIds.has(op.id))
      .map((op) => op.id)

    if (keys.length === 0) return 0
    await this.db.operations.bulkDelete(keys)
    return keys.length
  }

  async requeueForRetry(id: string): Promise<void> {
    const op = await this.db.operations.get(id)
    if (!op) return

    await this.db.operations.update(id, {
      status: 'pending',
      next_retry_at: new Date().toISOString(), // elegible al pròxim cicle (30s)
      retry_count: 0,
      last_error: undefined,
      sync_started_at: undefined,
      payload: normalizePayloadForManualRetry(op),
    })
  }

  async getSyncState(): Promise<SyncState> {
    const state = await this.db.sync_state.get('singleton')
    return (
      state ?? {
        id: 'singleton',
        lastSyncAt: null,
        isSyncing: false,
        consecutiveErrors: 0,
      }
    )
  }

  async updateSyncState(patch: Partial<Omit<SyncState, 'id'>>): Promise<void> {
    await this.db.sync_state.put({
      ...(await this.getSyncState()),
      ...patch,
    })
  }

  async countPending(tenantId: string): Promise<number> {
    return this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, 'pending', Dexie.minKey], [tenantId, 'pending', Dexie.maxKey])
      .count()
  }
}

// ---------------------------------------------------------------------------
// Adaptador in-memory (fallback per a Safari Private o entorns sense IndexedDB)
// ---------------------------------------------------------------------------

class InMemoryAdapter implements FieldOpsAdapter {
  private ops = new Map<string, LocalFieldOp>()
  private state: SyncState = {
    id: 'singleton',
    lastSyncAt: null,
    isSyncing: false,
    consecutiveErrors: 0,
  }

  async enqueueOp(op: LocalFieldOp): Promise<void> {
    const pending = await this.countPending(op.tenant_id)
    if (pending >= MAX_PENDING) {
      throw new Error(`Límit d'operacions pendents (${MAX_PENDING}) superat`)
    }
    this.ops.set(op.id, op)
  }

  async nextPendingBatch(
    tenantId: string,
    size = 20,
    mode: 'non_close' | 'close' | 'all' = 'all',
    projectId?: string,
  ): Promise<LocalFieldOp[]> {
    const now = new Date().toISOString()
    return Array.from(this.ops.values())
      .filter(
        (op) =>
          op.tenant_id === tenantId &&
          (!projectId || op.project_id === projectId) &&
          isFieldOpEligible(op, this.ops, now, mode),
      )
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .slice(0, size)
  }

  async markSyncing(ids: string[]): Promise<void> {
    const now = new Date().toISOString()
    for (const id of ids) {
      const op = this.ops.get(id)
      if (op) this.ops.set(id, { ...op, status: 'syncing', sync_started_at: now })
    }
  }

  async markSynced(id: string, serverId?: string): Promise<void> {
    const op = this.ops.get(id)
    if (op) {
      this.ops.set(id, {
        ...op,
        status: 'synced',
        sync_started_at: undefined,
        next_retry_at: undefined,
        last_error: undefined,
        ...(serverId ? { server_id: serverId } : {}),
      })
    }
  }

  async markRetryable(id: string, msg: string): Promise<void> {
    const op = this.ops.get(id)
    if (!op) return
    const newRetryCount = op.retry_count + 1
    this.ops.set(id, {
      ...op,
      status: 'pending',
      retry_count: newRetryCount,
      last_error: msg,
      next_retry_at: calcNextRetryAt(newRetryCount),
      sync_started_at: undefined,
    })
  }

  async markQuarantined(id: string, msg: string): Promise<void> {
    const op = this.ops.get(id)
    if (op) {
      this.ops.set(id, {
        ...op,
        status: 'quarantined',
        last_error: msg,
        sync_started_at: undefined,
      })
    }
  }

  async recoverStaleSyncing(tenantId: string, olderThanIso: string): Promise<number> {
    let count = 0
    for (const [id, op] of this.ops) {
      if (op.tenant_id === tenantId && isStaleSyncingOp(op, olderThanIso)) {
        this.ops.set(id, {
          ...op,
          status: 'pending',
          sync_started_at: undefined,
          next_retry_at: new Date().toISOString(),
        })
        count += 1
      }
    }
    return count
  }

  async listProjectOps(
    tenantId: string,
    projectId: string,
    statuses?: FieldOpStatus[],
  ): Promise<LocalFieldOp[]> {
    return Array.from(this.ops.values())
      .filter(
        (op) =>
          op.tenant_id === tenantId &&
          op.project_id === projectId &&
          (!statuses || statuses.includes(op.status)),
      )
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
  }

  async removeOp(id: string): Promise<void> {
    const target = this.ops.get(id)
    if (
      target &&
      Array.from(this.ops.values()).some(
        (op) =>
          op.tenant_id === target.tenant_id &&
          op.status !== 'synced' &&
          (op.depends_on ?? []).includes(id),
      )
    ) {
      throw new Error('field_op_is_dependency')
    }
    this.ops.delete(id)
  }

  async purgeSynced(tenantId: string, olderThanIso: string): Promise<number> {
    const referencedIds = new Set(
      Array.from(this.ops.values())
        .filter((op) => op.tenant_id === tenantId && op.status !== 'synced')
        .flatMap((op) => op.depends_on ?? []),
    )
    const ids = Array.from(this.ops.values())
      .filter(
        (op) =>
          op.tenant_id === tenantId &&
          op.status === 'synced' &&
          op.created_at < olderThanIso &&
          !referencedIds.has(op.id),
      )
      .map((op) => op.id)
    for (const id of ids) this.ops.delete(id)
    return ids.length
  }

  async countByStatus(tenantId: string, status: FieldOpStatus): Promise<number> {
    return Array.from(this.ops.values()).filter(
      (o) => o.tenant_id === tenantId && o.status === status,
    ).length
  }

  async listByStatus(tenantId: string, status: FieldOpStatus): Promise<LocalFieldOp[]> {
    return Array.from(this.ops.values())
      .filter((o) => o.tenant_id === tenantId && o.status === status)
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
  }

  async removeByStatus(tenantId: string, status: FieldOpStatus): Promise<number> {
    const referencedIds = new Set(
      Array.from(this.ops.values())
        .filter((op) => op.tenant_id === tenantId && op.status !== 'synced')
        .flatMap((op) => op.depends_on ?? []),
    )
    const ids = Array.from(this.ops.values())
      .filter(
        (o) =>
          o.tenant_id === tenantId &&
          o.status === status &&
          !referencedIds.has(o.id),
      )
      .map((o) => o.id)

    for (const id of ids) {
      this.ops.delete(id)
    }
    return ids.length
  }

  async requeueForRetry(id: string): Promise<void> {
    const op = this.ops.get(id)
    if (op) {
      this.ops.set(id, {
        ...op,
        status: 'pending',
        next_retry_at: new Date().toISOString(),
        retry_count: 0,
        last_error: undefined,
        sync_started_at: undefined,
        payload: normalizePayloadForManualRetry(op),
      })
    }
  }

  async getSyncState(): Promise<SyncState> {
    return this.state
  }

  async updateSyncState(patch: Partial<Omit<SyncState, 'id'>>): Promise<void> {
    this.state = { ...this.state, ...patch }
  }

  async countPending(tenantId: string): Promise<number> {
    return Array.from(this.ops.values()).filter(
      (o) => o.tenant_id === tenantId && o.status === 'pending',
    ).length
  }
}

// ---------------------------------------------------------------------------
// Factory — intenta Dexie, fa fallback a in-memory si IndexedDB no disponible
// ---------------------------------------------------------------------------

let _adapter: FieldOpsAdapter | null = null
let _isFallback = false

const IDB_OPEN_TIMEOUT_MS = 1500

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, timeoutError: Error): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(timeoutError), timeoutMs)
    promise
      .then((value) => {
        clearTimeout(timer)
        resolve(value)
      })
      .catch((err) => {
        clearTimeout(timer)
        reject(err)
      })
  })
}

export async function getFieldOpsAdapter(): Promise<{
  adapter: FieldOpsAdapter
  isFallback: boolean
}> {
  if (_adapter) return { adapter: _adapter, isFallback: _isFallback }

  try {
    const db = new FieldOpsDatabase()
    await withTimeout(
      db.open(),
      IDB_OPEN_TIMEOUT_MS,
      new Error('idb_open_timeout'),
    )
    _adapter = new DexieAdapter(db)
    _isFallback = false
  } catch {
    _adapter = new InMemoryAdapter()
    _isFallback = true
  }

  return { adapter: _adapter, isFallback: _isFallback }
}
