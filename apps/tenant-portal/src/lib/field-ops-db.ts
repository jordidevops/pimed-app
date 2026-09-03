import Dexie, { type Table } from 'dexie'

// ---------------------------------------------------------------------------
// Tipus
// ---------------------------------------------------------------------------

export type FieldOpKind = 'worklog.start' | 'worklog.stop'

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

export interface LocalFieldOp {
  /** UUID únic d'aquesta operació. S'envia com a v_op.id al batch. */
  id: string
  /** Tenant al qual pertany. Imprescindible per aïllament multi-tenant. */
  tenant_id: string
  kind: FieldOpKind
  status: FieldOpStatus
  /** ISO8601 — usada per ordenar el batch (start SEMPRE < stop del mateix log) */
  created_at: string
  /** work_log_id retornat pel servidor, guardat post-sync */
  server_id?: string
  retry_count: number
  last_error?: string
  /**
   * ISO8601 — quan pot tornar a entrar al batch. NULL = elegible immediatament.
   * Calculat amb backoff exponencial + jitter per evitar thundering herd.
   */
  next_retry_at?: string
  payload: WorklogStartPayload | WorklogStopPayload
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

function normalizePayloadForManualRetry(op: LocalFieldOp): LocalFieldOp['payload'] {
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
  nextPendingBatch(tenantId: string, size?: number): Promise<LocalFieldOp[]>
  markSyncing(ids: string[]): Promise<void>
  markSynced(id: string, serverId?: string): Promise<void>
  markRejected(id: string, msg: string): Promise<void>
  markQuarantined(id: string, msg: string): Promise<void>
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

  async nextPendingBatch(tenantId: string, size = 20): Promise<LocalFieldOp[]> {
    const now = new Date().toISOString()
    // Filtre next_retry_at en JS (bounded per MAX_PENDING=500, mínim overhead)
    const all = await this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, 'pending', Dexie.minKey], [tenantId, 'pending', Dexie.maxKey])
      .sortBy('created_at')
    return all
      .filter((o) => o.next_retry_at == null || o.next_retry_at <= now)
      .slice(0, size)
  }

  async markSyncing(ids: string[]): Promise<void> {
    await this.db.operations
      .where('id')
      .anyOf(ids)
      .modify({ status: 'syncing' })
  }

  async markSynced(id: string, serverId?: string): Promise<void> {
    await this.db.operations.update(id, {
      status: 'synced',
      ...(serverId ? { server_id: serverId } : {}),
    })
  }

  async markRejected(id: string, msg: string): Promise<void> {
    const op = await this.db.operations.get(id)
    if (!op) return
    const newRetryCount = op.retry_count + 1
    await this.db.operations.update(id, {
      status: 'rejected',
      retry_count: newRetryCount,
      last_error: msg,
      next_retry_at: calcNextRetryAt(newRetryCount),
    })
  }

  async markQuarantined(id: string, msg: string): Promise<void> {
    await this.db.operations.update(id, {
      status: 'quarantined',
      last_error: msg,
    })
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
    const keys = await this.db.operations
      .where('[tenant_id+status+created_at]')
      .between([tenantId, status, Dexie.minKey], [tenantId, status, Dexie.maxKey])
      .primaryKeys() as string[]

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

  async nextPendingBatch(tenantId: string, size = 20): Promise<LocalFieldOp[]> {
    const now = new Date().toISOString()
    return Array.from(this.ops.values())
      .filter(
        (o) =>
          o.tenant_id === tenantId &&
          o.status === 'pending' &&
          (o.next_retry_at == null || o.next_retry_at <= now),
      )
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .slice(0, size)
  }

  async markSyncing(ids: string[]): Promise<void> {
    for (const id of ids) {
      const op = this.ops.get(id)
      if (op) this.ops.set(id, { ...op, status: 'syncing' })
    }
  }

  async markSynced(id: string, serverId?: string): Promise<void> {
    const op = this.ops.get(id)
    if (op) this.ops.set(id, { ...op, status: 'synced', ...(serverId ? { server_id: serverId } : {}) })
  }

  async markRejected(id: string, msg: string): Promise<void> {
    const op = this.ops.get(id)
    if (!op) return
    const newRetryCount = op.retry_count + 1
    this.ops.set(id, {
      ...op,
      status: 'rejected',
      retry_count: newRetryCount,
      last_error: msg,
      next_retry_at: calcNextRetryAt(newRetryCount),
    })
  }

  async markQuarantined(id: string, msg: string): Promise<void> {
    const op = this.ops.get(id)
    if (op) this.ops.set(id, { ...op, status: 'quarantined', last_error: msg })
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
    const ids = Array.from(this.ops.values())
      .filter((o) => o.tenant_id === tenantId && o.status === status)
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
