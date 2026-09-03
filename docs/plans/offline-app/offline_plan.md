# Tech Portal — Pla d'implementació Offline-First

**Estat:** Proposta d'arquitectura  
**Data:** 2026-06-05  
**Àmbit:** `apps/tech-portal/`  
**Prerequisits:** Sprint 4 (UI tècnic, SDK Data Connect, Firebase Auth/Storage) completat en línia.

## TL;DR

| Capa | Tecnologia | Rol |
|------|------------|-----|
| App Shell | `vite-plugin-pwa` + Workbox | JS/CSS/HTML/icons sempre disponibles sense xarxa |
| Lectura | Dexie.js + React Query | Caché normalitzada de queries GQL + UI reactiva |
| Escriptura | Cua de mutacions (Dexie) | Totes les accions offline → sync seqüencial |
| Fitxers | Blobs a IndexedDB → Firebase Storage | Pujar abans de mutacions que referencien `bucketPath` |
| Orquestració | `SyncManager` (singleton + `online`/`offline`) | Buidatge de cua amb dependències i reintents |

**Decisió clau:** El Service Worker **no** intercepta crides a Data Connect ni Cloud Functions. Només serveix l'app shell. La coherència de dades és responsabilitat de l'aplicació (Dexie + cua).

---

## Context del codi actual

El tech-portal ja té:

- React 19 + Vite 8 + TanStack Query 5.
- Mutacions directes al SDK (`startTransit`, `checkInWorkOrder`, `upsertIncidentDiagnostic`, etc.) amb `QueryFetchPolicy.SERVER_ONLY` a la lectura.
- `createIncident` via `httpsCallable` (no és mutació GQL pura).
- Firebase Storage inicialitzat a `src/lib/firebase.ts` (patró d'upload similar a `useUpdateElevatorSpec` del tenant-portal).

**Canvi d'arquitectura:** cap component cridarà `executeQuery` / mutacions SDK directament en mode camp. Passaran per una capa `offline/*` que llegeix Dexie i enqueua escriptures.

---

## Fase 0 — Preparació (1–2 dies)

### 0.1 Estructura de carpetes proposada

```
apps/tech-portal/src/
  offline/
    db.ts                 # Dexie singleton + migracions
    schema.ts             # Tipus de stores
    network.ts            # navigator.onLine + events
    sync-manager.ts       # Motor de cua
    sync-handlers/        # Un handler per tipus d'acció
    repository/           # read/write sobre Dexie (no React)
    prefetch.ts           # Job "baixar el dia"
  hooks/
    useNetworkStatus.ts
    useOfflineQuery.ts
    useOfflineMutation.ts
    useSyncStatus.ts
  providers/
    OfflineProvider.tsx
  workers/
    image-compress.worker.ts
```

### 0.2 Dependències

```bash
cd apps/tech-portal
npm i dexie dexie-react-hooks browser-image-compression uuid
npm i -D vite-plugin-pwa workbox-window
```

| Paquet | Motiu |
|--------|--------|
| **Dexie.js** | Esquema versionat, índexs, transaccions, API de cua ordenada, suport Blob natiu |
| `dexie-react-hooks` | `useLiveQuery` per UI sense reimplementar subscripcions |
| `browser-image-compression` | Compressió JPEG/WebP provada; fàcil moure a Worker |
| `vite-plugin-pwa` | Integració Workbox + manifest sense ejectar Vite |

**Per què Dexie i no `idb`?**  
`idb` és un wrapper prim de Promises. Aquí necessitem: migracions (`db.version(n)`), consultes per `status`/`createdAt`, transaccions multi-store (blob + cua + entitat), i integració amb hooks React. Dexie redueix boilerplate per un sistema amb 4+ object stores i anys de versions.

### 0.3 Regles d'auth offline

- Firebase Auth ja persisteix la sessió al navegador; el tècnic pot obrir l'app offline **si ja ha fet login online** almenys una vegada.
- Documentar UX: pantalla de login offline → missatge "cal connexió per iniciar sessió".
- Token refresh: en `online`, abans de processar la cua, `await auth.currentUser?.getIdToken(true)` per evitar mutacions amb token caducat.

---

## Fase 1 — Configuració PWA

### 1.1 `vite.config.ts`

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      includeAssets: ['favicon.ico', 'icons/*.png'],
      manifest: {
        name: 'APP Tech',
        short_name: 'Tech',
        description: 'Portal tècnic de camp',
        theme_color: '#0f172a',
        background_color: '#0f172a',
        display: 'standalone',
        orientation: 'portrait',
        scope: '/',
        start_url: '/',
        icons: [
          { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/icons/icon-512-maskable.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api\//],
        runtimeCaching: [
          {
            // Tiles Leaflet (opcional): cache curta, no bloqueja offline core
            urlPattern: /^https:\/\/.*\.tile\.openstreetmap\.org\/.*/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'map-tiles',
              expiration: { maxEntries: 200, maxAgeSeconds: 60 * 60 * 24 * 7 },
            },
          },
        ],
      },
      devOptions: { enabled: true }, // provar SW en dev
    }),
  ],
  server: { port: 3001 },
});
```

### 1.2 Estratègia de memòria cau (assets)

| Recurs | Estratègia Workbox | Raó |
|--------|-------------------|-----|
| `index.html`, chunks JS/CSS (build) | **Precache** (`globPatterns`) | App shell 100% offline després de 1ª visita |
| Fonts/icones locals | Precache via `includeAssets` | Evitar FOUC offline |
| Tiles mapa | **CacheFirst** (runtime, opcional) | UX mapa; no crític per WO |
| API Data Connect / Functions / Storage upload | **Cap cache SW** | Dades sensibles + coherència = capa app |

### 1.3 `main.tsx` — registre i actualització

```ts
import { registerSW } from 'virtual:pwa-register';

const updateSW = registerSW({
  onNeedRefresh() {
    // Mostrar toast: "Nova versió disponible" → updateSW(true)
  },
  onOfflineReady() {
    console.info('[PWA] App shell llest per offline');
  },
});
```

### 1.4 `index.html` i icons

- Afegir `meta name="theme-color"`, `apple-mobile-web-app-capable`.
- Generar `public/icons/` (192, 512, maskable) — reutilitzar branding APP.

### 1.5 Checklist PWA

- [ ] Lighthouse PWA ≥ 90 en build de producció.
- [ ] `npm run build && npm run preview` → tallar xarxa → app arrenca i navega entre rutes cached.
- [ ] Verificar que **no** es cachegen respostes de `firebase/data-connect` al SW (DevTools → Application → Cache Storage).

---

## Fase 2 — Arquitectura IndexedDB (Dexie)

### 2.1 Esquema de dades local

Separació explícita entre **caché de lectura** (replícable, es pot tornar a baixar) i **cua de mutacions** (font de veritat fins a sync).

```ts
// offline/schema.ts
export type EntityTable =
  | 'tenantMember'
  | 'workOrder'
  | 'workOrderDetail'      // payload complet GetWorkOrder
  | 'incident'
  | 'elevator'
  | 'diagnosticTemplate'
  | 'incidentDiagnostic';

export type MutationStatus = 'pending' | 'processing' | 'failed' | 'done';
export type MutationKind =
  | 'STORAGE_UPLOAD'
  | 'DATACONNECT'
  | 'CALLABLE';           // createIncident, etc.

export interface CachedEntity {
  id: string;               // clau composta: `${table}:${tenantId}:${id}`
  table: EntityTable;
  tenantId: string;
  payload: unknown;         // JSON serialitzable
  updatedAt: number;        // server o local
  syncedAt: number | null;
}

export interface LocalBlob {
  id: string;               // uuid local
  tenantId: string;
  mimeType: string;
  sizeBytes: number;
  blob: Blob;
  createdAt: number;
  /** Omplert després de pujar */
  bucketPath?: string;
  downloadUrl?: string;
}

export interface MutationQueueItem {
  id: string;
  tenantId: string;
  kind: MutationKind;
  status: MutationStatus;
  /** Ordre global dins el tenant (enter creixent) */
  seq: number;
  /** IDs d'items que han d'estar `done` abans d'executar aquest */
  dependsOn: string[];
  /** Handler key: 'workOrder.startTransit', 'diagnostic.upsert', ... */
  action: string;
  payload: Record<string, unknown>;
  /** Referències a LocalBlob.id */
  blobIds: string[];
  attempts: number;
  lastError?: string;
  createdAt: number;
  processedAt?: number;
  /** ID temporal client (UUID) per idempotència / upsert offline */
  clientMutationId: string;
}

export interface SyncMeta {
  key: string;              // 'lastPrefetch', 'queuePaused', ...
  value: unknown;
}
```

### 2.2 Definició Dexie

```ts
// offline/db.ts
import Dexie, { type Table } from 'dexie';

export class TechOfflineDB extends Dexie {
  entities!: Table<CachedEntity, string>;
  blobs!: Table<LocalBlob, string>;
  mutationQueue!: Table<MutationQueueItem, string>;
  meta!: Table<SyncMeta, string>;

  constructor() {
    super('tech-portal-offline');
    this.version(1).stores({
      entities: 'id, table, tenantId, updatedAt',
      blobs: 'id, tenantId, createdAt',
      mutationQueue: 'id, tenantId, status, seq, createdAt',
      meta: 'key',
    });
  }
}

export const offlineDb = new TechOfflineDB();
```

### 2.3 Claus de caché (alineades amb React Query)

Mapeig per facilitar migració gradual:

| React Query key actual | Entity `table` | Clau Dexie `id` |
|------------------------|----------------|-----------------|
| `['myTenantMember', tenantId]` | `tenantMember` | `tenantMember:{tenantId}:self` |
| `['workOrders', tenantId, memberId, date]` | `workOrder` | múltiples files per WO id |
| `['workOrder', tenantId, woId]` | `workOrderDetail` | `workOrderDetail:{tenantId}:{woId}` |
| `['diagnostic-templates-all', tenantId]` | `diagnosticTemplate` | una fila agregada o N files |

### 2.4 Prefetch ("baixar el dia")

Job executat manualment (botó Perfil) o automàtic en `online` al matí:

1. `GetMyTenantMember`
2. `listWorkOrders` (avui + demà opcional)
3. Per cada WO actiu: `GetWorkOrder` + diagnostics + plantilles
4. Elevadors vinculats (si `TechElevatorDetailPage` ho necessita)

```ts
// offline/prefetch.ts (pseudocodi)
export async function prefetchTechDay(tenantId: string, memberId: string) {
  const date = todayISO();
  const member = await fetchAndCache('tenantMember', ...);
  const orders = await fetchListWorkOrders(tenantId, memberId, date);
  for (const wo of orders) {
    await fetchAndCacheWorkOrderDetail(tenantId, wo.id);
  }
  await offlineDb.meta.put({ key: `lastPrefetch:${tenantId}`, value: Date.now() });
}
```

### 2.5 Política de lectura offline

```ts
// offline/repository/read.ts
export async function getCachedOrFetch<T>(
  entityId: string,
  fetcher: () => Promise<T>,
  opts: { forceNetwork?: boolean }
): Promise<T> {
  if (!navigator.onLine && !opts.forceNetwork) {
    const row = await offlineDb.entities.get(entityId);
    if (!row) throw new OfflineCacheMissError(entityId);
    return row.payload as T;
  }
  const data = await fetcher();
  await offlineDb.entities.put({ id: entityId, ... , payload: data, syncedAt: Date.now() });
  return data;
}
```

---

## Fase 3 — Tractament d'imatges al frontend

### 3.1 Flux recomanat

```
[input capture / galeria]
    → validar mida (< 15 MB raw)
    → Web Worker: resize + compress (max 1920px, quality 0.8, JPEG/WebP)
    → Blob → offlineDb.blobs.add
    → enqueue STORAGE_UPLOAD (sense dependències)
    → enqueue DATACONNECT (dependsOn: [uploadId]) amb bucketPath al payload
```

### 3.2 Worker de compressió

```ts
// workers/image-compress.worker.ts
import imageCompression from 'browser-image-compression';

self.onmessage = async (e: MessageEvent<{ file: File }>) => {
  const { file } = e.data;
  const compressed = await imageCompression(file, {
    maxSizeMB: 1.5,
    maxWidthOrHeight: 1920,
    useWebWorker: false, // ja som dins un worker
    fileType: 'image/jpeg',
  });
  self.postMessage({ blob: compressed }, [/* transfer si suportat */]);
};
```

### 3.3 API d'ús des de React (no bloqueja UI)

```ts
// offline/media/store-local-image.ts
export async function storeLocalImage(file: File, tenantId: string): Promise<string> {
  const blob = await compressInWorker(file);
  const id = crypto.randomUUID();
  await offlineDb.blobs.add({
    id,
    tenantId,
    mimeType: blob.type,
    sizeBytes: blob.size,
    blob,
    createdAt: Date.now(),
  });
  return id;
}
```

```ts
// Component
const localBlobId = await storeLocalImage(file, tenantId);
await enqueueMutation({
  action: 'media.upload',
  kind: 'STORAGE_UPLOAD',
  blobIds: [localBlobId],
  payload: { fieldKey: 'photoEvidence', workOrderId, elevatorId },
});
```

### 3.4 Convenció de paths Storage (alineada amb tenant-portal)

```
{tenantId}/work-orders/{workOrderId}/evidence/{fileId}.jpg
{tenantId}/incidents/{incidentId}/photos/{fileId}.jpg
```

Després de `uploadBytes`, la mutació GQL (o callable) rep `bucketPath` — **mai** una URL signada a la cua (caduca).

### 3.5 Neteja

- Després de `MutationQueueItem.status === 'done'`: esborrar blob local si `downloadUrl` ja no cal offline.
- Política: conservar blobs de mutacions `failed` per reintent manual.

---

## Fase 4 — Motor de sincronització (Sync Manager)

### 4.1 Singleton i esdeveniments de xarxa

```ts
// offline/network.ts
type Listener = (online: boolean) => void;

export const network = {
  get isOnline() {
    return typeof navigator !== 'undefined' ? navigator.onLine : true;
  },
  subscribe(fn: Listener) {
    const on = () => fn(true);
    const off = () => fn(false);
    window.addEventListener('online', on);
    window.addEventListener('offline', off);
    return () => {
      window.removeEventListener('online', on);
      window.removeEventListener('offline', off);
    };
  },
};
```

```ts
// offline/sync-manager.ts
class SyncManager {
  private running = false;
  private paused = false;

  start() {
    network.subscribe((online) => {
      if (online) void this.drain();
    });
    if (network.isOnline) void this.drain();
  }

  async drain() {
    if (this.running || this.paused || !network.isOnline) return;
    this.running = true;
    try {
      await refreshAuthToken();
      const items = await offlineDb.mutationQueue
        .where('status')
        .anyOf(['pending', 'failed'])
        .sortBy('seq');

      for (const item of items) {
        if (!(await dependenciesMet(item))) continue;
        await this.processOne(item);
      }
    } finally {
      this.running = false;
    }
  }
}

export const syncManager = new SyncManager();
```

### 4.2 Registre de handlers

```ts
// offline/sync-handlers/registry.ts
type Handler = (item: MutationQueueItem) => Promise<void>;

export const handlers: Record<string, Handler> = {
  'media.upload': async (item) => {
    const blob = await offlineDb.blobs.get(item.blobIds[0]!);
    const bucketPath = buildPath(item.payload);
    await uploadBytes(ref(storage, bucketPath), blob!.blob, { contentType: blob!.mimeType });
    await offlineDb.blobs.update(blob!.id, { bucketPath });
    // Desar bucketPath al payload per handlers dependents (via meta o merge)
    await patchItemPayload(item.id, { bucketPath });
  },

  'workOrder.startTransit': async (item) => {
    await startTransit(item.payload as StartTransitVariables);
  },

  'diagnostic.upsert': async (item) => {
    await upsertIncidentDiagnostic(item.payload as UpsertVars);
  },

  'incident.create': async (item) => {
    await httpsCallable(functions, 'createIncident')(item.payload);
  },
};
```

### 4.3 Dependències (graf simple)

Exemple real del projecte (completar WO amb foto + diagnostic):

```
[STORAGE_UPLOAD id=A]  photo evidència
        ↓ dependsOn
[DATACONNECT id=B]     attachEvidence(bucketPath)  // futura mutació GQL
        ↓ dependsOn (opcional)
[DATACONNECT id=C]     completeWorkOrder
```

```ts
async function dependenciesMet(item: MutationQueueItem): Promise<boolean> {
  if (!item.dependsOn.length) return true;
  const deps = await offlineDb.mutationQueue.bulkGet(item.dependsOn);
  return deps.every((d) => d?.status === 'done');
}
```

**Regla:** assignar `seq` monòton (`max(seq)+1`) en enqueue. `dependsOn` només per ordre lògic entre tipus diferents; dins el mateix WO, l'usuari no hauria de poder completar fins que les dependències estiguin fetes (validació UI).

### 4.4 Enqueue API (punt únic d'escriptura)

```ts
export async function enqueueMutation(
  input: Omit<MutationQueueItem, 'id' | 'status' | 'seq' | 'attempts' | 'createdAt' | 'clientMutationId'> &
    { clientMutationId?: string }
) {
  const seq = (await offlineDb.mutationQueue.orderBy('seq').last())?.seq ?? 0;
  const item: MutationQueueItem = {
    ...input,
    id: crypto.randomUUID(),
    clientMutationId: input.clientMutationId ?? crypto.randomUUID(),
    status: 'pending',
    seq: seq + 1,
    attempts: 0,
    createdAt: Date.now(),
  };
  await offlineDb.mutationQueue.add(item);
  await applyOptimisticPatch(item);  // actualitza entities + invalida React Query
  if (network.isOnline) void syncManager.drain();
  return item.id;
}
```

### 4.5 Gestió d'errors i reintents

| Tipus d'error | Acció |
|---------------|--------|
| Xarxa / timeout | `status → pending`, reintent exponencial (cap a 5 intents) |
| 401 / token | refresh token + reintent immediat |
| 409 / conflicte FSM (WO ja completat) | `status → failed`, `lastError` llegible, **no** reintent automàtic |
| 4xx validació | `failed` + notificació usuari |
| 5xx servidor | reintent amb backoff: `min(2^attempts * 1000, 60000)` ms |

```ts
async function processOne(item: MutationQueueItem) {
  await offlineDb.mutationQueue.update(item.id, { status: 'processing' });
  try {
    await handlers[item.action](item);
    await offlineDb.mutationQueue.update(item.id, {
      status: 'done',
      processedAt: Date.now(),
    });
  } catch (err) {
    const attempts = item.attempts + 1;
    const retriable = isRetriable(err);
    await offlineDb.mutationQueue.update(item.id, {
      status: retriable && attempts < 5 ? 'pending' : 'failed',
      attempts,
      lastError: serializeError(err),
    });
    if (retriable && attempts < 5) {
      await sleep(backoffMs(attempts));
    }
  }
}
```

### 4.6 Idempotència amb Data Connect

- Incloure `clientMutationId` a payloads on el backend suporti clau client (o camp `offlineId` a taules d'evidències).
- Per mutacions FSM (`startTransit`, etc.): el servidor ja ha de retornar error si transició invàlida — tractar com a `failed` i refrescar WO des de xarxa.
- **No** duplicar uploads Storage: abans de pujar, comprovar si `blob.bucketPath` ja existeix.

### 4.7 Concurrència

- Un sol `drain()` actiu (`running` lock).
- Processament **seqüencial** per `seq` global per tenant (evita races FSM).
- Opcional futur: paral·lelitzar només `STORAGE_UPLOAD` de diferents WO si cal rendiment.

---

## Fase 5 — Hooks i components React

### 5.1 Arbre de providers

```tsx
// App.tsx (objectiu final)
<QueryClientProvider client={queryClient}>
  <AuthProvider>
    <TenantProvider>
      <OfflineProvider>           {/* syncManager.start(), network, pending count */}
        <BrowserRouter>...</BrowserRouter>
      </OfflineProvider>
    </TenantProvider>
  </AuthProvider>
</QueryClientProvider>
```

### 5.2 Hooks proposats

| Hook | Responsabilitat |
|------|-----------------|
| `useNetworkStatus()` | `{ isOnline, wasOffline }` des de `network.subscribe` |
| `useSyncStatus()` | `{ isSyncing, pendingCount, failedCount, lastSyncAt }` |
| `useOfflineQuery(key, fetcher, opts)` | Llegeix Dexie si offline; si online, fetch + cache |
| `useOfflineMutation(action, opts)` | `enqueueMutation` + optimistic update |
| `usePendingMutations(entityId?)` | `useLiveQuery` sobre `mutationQueue` |
| `usePrefetch()` | `prefetchTechDay` + estat loading |

### 5.3 `OfflineProvider` + banner UI

```tsx
// providers/OfflineProvider.tsx
export function OfflineProvider({ children }: { children: React.ReactNode }) {
  const isOnline = useNetworkStatus();
  const { pendingCount, failedCount, isSyncing } = useSyncStatus();

  useEffect(() => {
    syncManager.start();
  }, []);

  return (
    <OfflineContext.Provider value={{ isOnline, pendingCount, failedCount, isSyncing }}>
      {!isOnline && <OfflineBanner />}
      {pendingCount > 0 && isOnline && <SyncingBanner count={pendingCount} />}
      {failedCount > 0 && <SyncFailedBanner />}
      {children}
    </OfflineContext.Provider>
  );
}
```

### 5.4 Migració gradual de pàgines

| Pàgina | Canvi |
|--------|--------|
| `TechDashboardPage` | `useOfflineQuery` per member + work orders |
| `WorkOrderDetailPage` | Mutacions FSM → `useOfflineMutation('workOrder.*')` |
| `DiagnosticSection` | `upsertIncidentDiagnostic` → cua |
| `CreateIncidentDrawer` | `CALLABLE` handler |
| `ProfilePage` | Botó "Baixar dades del dia" → `usePrefetch` |

### 5.5 `useOfflineMutation` (esquelet)

```ts
export function useOfflineMutation<TPayload>(
  action: string,
  options?: {
    kind?: MutationKind;
    optimisticUpdate?: (payload: TPayload) => Promise<void>;
    dependsOn?: (payload: TPayload) => string[];
  }
) {
  const { activeTenantId } = useTenant();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (payload: TPayload & { blobIds?: string[] }) => {
      const id = await enqueueMutation({
        tenantId: activeTenantId!,
        action,
        kind: options?.kind ?? 'DATACONNECT',
        payload: payload as Record<string, unknown>,
        blobIds: payload.blobIds ?? [],
        dependsOn: options?.dependsOn?.(payload) ?? [],
      });
      return id;
    },
    onMutate: async (payload) => {
      await options?.optimisticUpdate?.(payload);
    },
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: ['workOrder'] });
    },
  });
}
```

### 5.6 Components nous (UX camp)

- `SyncStatusChip` — a `TechShell` (badge amb `pendingCount`).
- `PendingActionsDrawer` — llista cua + botó "Reintentar" per `failed`.
- `OfflineLoginHint` — a `LoginPage` si `!navigator.onLine`.

---

## Fase 6 — Integració React Query

### 6.1 Persistència opcional (no substitueix Dexie)

Es pot afegir `@tanstack/react-query-persist-client` **només** per hidratar UI ràpid, però la font de veritat offline ha de ser Dexie (suport blobs + cua).

Config recomanada:

```ts
// lib/react-query.ts — ampliar
defaultOptions: {
  queries: {
    staleTime: 1000 * 60 * 2,
    retry: (failureCount, error) => {
      if (!navigator.onLine) return false;
      return failureCount < 1;
    },
    networkMode: 'offlineFirst', // TanStack Query v5
  },
  mutations: {
    networkMode: 'offlineFirst',
  },
},
```

### 6.2 Invalidació post-sync

`syncManager` emet esdeveniments (`sync:item-done`, `sync:drain-complete`) que `OfflineProvider` escolta per `queryClient.invalidateQueries` selectiu.

---

## Fase 7 — Ordre d'implementació (cronograma suggerit)

| Setmana | Entregable | Criteri d'acceptació |
|---------|------------|----------------------|
| 1 | PWA + icons + manifest | App shell offline en preview build |
| 1–2 | Dexie schema + repository read | Dashboard mostra WO cached sense xarxa |
| 2 | Prefetch + Profile CTA | Tècnic baixa el dia manualment |
| 3 | `enqueueMutation` + SyncManager (només DATACONNECT) | `startTransit` offline → sync al reconnectar |
| 3–4 | Imatges + STORAGE_UPLOAD + dependències | Foto + mutació en cadena |
| 4 | Diagnostics + CreateIncident a cua | Flux complet revisió |
| 5 | UX failed/retry + tests E2E offline | Playwright: offline → actuar → online → assert DB |

---

## Fase 8 — Proves i observabilitat

### 8.1 Tests manual (Chrome DevTools)

1. Application → Service Workers → Offline.
2. Application → IndexedDB → `tech-portal-offline`.
3. Realitzar transit + check-in offline.
4. Desmarcar Offline → verificar cua buida i UI coherent.

### 8.2 Tests automatitzats

```ts
// e2e/offline-work-order.spec.ts (pseudocodi Playwright)
await context.setOffline(true);
await page.click('[data-testid=wo-start-transit]');
await expect(page.locator('[data-testid=sync-pending]')).toHaveText('1');
await context.setOffline(false);
await expect(page.locator('[data-testid=sync-pending]')).toHaveText('0', { timeout: 30000 });
```

### 8.3 Logging

Prefix `[offline]` a tota la cua; en producció, enviar només errors `failed` a Crashlytics / Sentry (fase posterior).

---

## Riscos i mitigacions

| Risc | Mitigació |
|------|-----------|
| FSM Work Order rebutja transició després de sync tardà | Missatge clar + `refetch` WO; marcar mutació `failed` |
| Callable `createIncident` no idempotent | Passar `clientMutationId` al callable; dedup al backend |
| IndexedDB quota (fotos) | Compressió agressiva + límit fotos per WO + neteja post-sync |
| SW cacheja build antic | `registerType: 'autoUpdate'` + toast refresh |
| Token Auth caducat offline llarg | Forçar re-login si > 7 dies sense `online` (configurable) |

---

## Referències internes

- `docs/plans/sprint4-tech-portal.md` — scope inicial (PWA explícitament fora de scope; ara entra).
- `apps/tenant-portal/src/hooks/useUpdateElevatorSpec.ts` — patró Storage → mutació GQL.
- `apps/tech-portal/src/pages/WorkOrderDetailPage.tsx` — mutacions FSM a encapsular.
- `apps/tech-portal/src/components/DiagnosticSection.tsx` — lectures `CACHE_AND_NETWORK` vs `SERVER_ONLY` a unificar via `useOfflineQuery`.

---

## Annex A — Mapa d'accions de la cua (inicial)

| `action` | `kind` | SDK / API |
|----------|--------|-----------|
| `workOrder.startTransit` | DATACONNECT | `startTransit` |
| `workOrder.checkIn` | DATACONNECT | `checkInWorkOrder` |
| `workOrder.complete` | DATACONNECT | `completeWorkOrder` + opcional `resolveIncident` |
| `workOrder.pause` | DATACONNECT | `putWorkOrderOnHold` |
| `workOrder.escalate` | DATACONNECT | `escalateWorkOrder` |
| `workOrder.reactivate` | DATACONNECT | `reactivateWorkOrder` |
| `diagnostic.upsert` | DATACONNECT | `upsertIncidentDiagnostic` |
| `diagnostic.assignTemplate` | DATACONNECT | `updateIncidentDiagnosticTemplate` |
| `incident.create` | CALLABLE | `createIncident` |
| `media.upload` | STORAGE_UPLOAD | `uploadBytes` |
| `geohash.update` | DATACONNECT | `updateMyGeohash` (baixa prioritat) |

---

## Annex B — Checklist de definició de fet (DoD)

- [ ] Tècnic obre l'app en mode avió amb sessió prèvia → veu dashboard del dia prefetched.
- [ ] Pot fer transit, check-in, diagnostics i adjuntar foto sense xarxa.
- [ ] En recuperar xarxa, la cua es buida sola en ordre correcte.
- [ ] Errors no retriables queden visibles i no bloquegen la resta de la cua (skip + `failed`).
- [ ] Lighthouse PWA instal·lable.
- [ ] Cap secret ni token a IndexedDB fora del que ja gestiona Firebase Auth.
