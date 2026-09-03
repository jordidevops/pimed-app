# Eliminació de Documents al Mòdul DMS

## Visió General

El mòdul DMS suporta dues accions d'eliminació, amb permisos i efectes diferents:

| Acció | RPC | Qui pot fer-la | Condició addicional |
|---|---|---|---|
| **Treure última versió** | `api.delete_document_latest_version` | owner/manager (global o site) o creador de la versió | El document ha de tenir ≥2 versions |
| **Eliminar document complet** | `api.delete_document_all` | owner/manager (global o site) o propietari de **totes** les versions | — |

---

## Model de Permisos

### "Propietari del document" vs "Propietari d'una versió"

- **`data.documents.created_by`**: autor de la primera versió del document. Determina qui és propietari del document.
- **`data.document_versions.created_by`**: autor de cada versió concreta.

Ambdós camps es poblen via `auth.uid()` en el moment de creació:
- `api.create_document_with_version` escriu `created_by = auth.uid()` a `data.documents`.
- `api.add_document_version` escriu `created_by = auth.uid()` a la nova versió.

### Regla del NULL

Si `created_by` és `NULL` (versions importades, migrades o creades sense context d'autenticació), la via "propietari de totes les versions" per a `delete_document_all` queda bloquejada. Només `owner`/`manager` poden eliminar documents en aquest cas.

### Jerarquia de rols

```
owner > manager > member/viewer
```

Els rols `owner` i `manager` poden operar tant a nivell global com de site (quan el document té `site_id`).

---

## Flux d'Eliminació

### Treure última versió (`delete_document_latest_version`)

```
Usuari → RPC (SECURITY DEFINER)
  1. Carrega document (NOT FOUND → error)
  2. Valida coherència tenant actiu (header x-tenant-id)
  3. Valida membresia al tenant via jwt_user_tenants()
  4. Carrega versió amb version_number màxim
  5. Comprova permís (owner/manager global, site manager, o creador de la versió)
  6. Verifica que el document té ≥2 versions
     → si n'hi ha 1: error "last_version_cannot_be_deleted"
  7. Encua esborrat físic a trash_deletion_queue (si storage_type = 'native')
  8. DELETE data.document_versions WHERE id = v_latest.id
     → trigger trg_audit_document_versions → DOCUMENT_VERSION_DELETED a audit_logs
```

**Resultat:**
- La vista `api.active_documents` reflecteix la versió anterior com a activa.
- El fitxer físic s'esborra en el proper cicle del worker (màx 5 min).

### Eliminar document complet (`delete_document_all`)

```
Usuari → RPC (SECURITY DEFINER)
  1. Carrega document (NOT FOUND → error)
  2. Valida coherència tenant actiu
  3. Valida membresia al tenant
  4. Comprova permís:
     a) owner/manager global/site → passi directament
     b) Altrament: bool_and(created_by = auth.uid()) sobre TOTES les versions
        → si alguna versió té created_by NULL o d'un altre usuari: accés denegat
  5. Encua esborrat físic de TOTS els fitxers natius a trash_deletion_queue
  6. DELETE data.documents WHERE id = p_document_id
     → CASCADE elimina data.document_versions
     → trigger trg_audit_documents → DOCUMENT_DELETED
     → trigger trg_audit_document_versions → DOCUMENT_VERSION_DELETED per cada versió
```

---

## Esborrat Físic (Storage)

### Arquitectura

L'esborrat del fitxer físic NO és síncron. Segueix el patró de cua asíncrona:

```
RPC SQL  ──pgmq.send──►  trash_deletion_queue  ──pg_cron (5min)──►  process-deletion-queue (Edge Function)
                                                                          │
                                                                          ├─ Supabase Storage: DELETE /objects/documents/{path}
                                                                          └─ BYOS (S3/R2/GCS): s3.send(DeleteObjectCommand)
```

### Payload de la cua

```json
{
  "tenant_id": "<uuid>",
  "idempotency_key": "doc-ver-del-<version_id>",
  "file_node_id": "<version_id>",
  "storage_provider_id": null,
  "storage_key": "<tenant_id>/<uuid>/filename.pdf",
  "bucket": "documents"
}
```

- `bucket: "documents"` distingeix el bucket DMS del bucket principal (`tenant-files`).
- El worker `process-deletion-queue` usa `payload.bucket ?? 'tenant-files'` per determinar el bucket destí.
- L'operació és **idempotent**: HTTP 404 del Storage es tracta com a èxit.

### Validació de seguretat del path

Les RPCs comproven que `file_path_or_url` compleixi el prefix `{tenant_id}/` abans d'encuar:

```sql
AND file_path_or_url LIKE (v_doc.tenant_id::text || '/%')
```

Paths que no compleixin el prefix (atac de path traversal cross-tenant) són **silenciosament ignorats** (no s'encuen).

### Consistència eventual

El disseny accepta consistència eventual (no ACID total) entre BD i Storage:

- **Cas normal**: DELETE BD → enqueue → worker esborra fitxer → arxiva missatge.
- **Fallada del worker**: fins a 3 reintents amb backoff exponencial. Après el 3r intent, el missatge va a DLQ i es genera una notificació als `owner` del tenant.
- **Fitxer ja absent**: el worker tracta HTTP 404 com a èxit (idempotent).
- **Rollback de la transacció BD**: el `pgmq.send` dins la mateixa transacció reverteix automàticament. El fitxer físic queda intacte.

---

## Auditoria

Totes les accions d'eliminació generen entrades a `data.audit_logs` via triggers ja existents:

| Trigger | Acció | entity_type |
|---|---|---|
| `trg_audit_documents` | `DOCUMENT_DELETED` | `document` |
| `trg_audit_document_versions` | `DOCUMENT_VERSION_DELETED` | `document_version` |

Els triggers s'executen **automàticament** en el `DELETE`. No cal codi extra a les RPCs.

---

## Frontend

### Permisos client-side (aproximació, validació definitiva al backend)

```typescript
const canDeleteLatest = canWrite || doc.version_created_by === user?.id
const canDeleteAll    = canWrite || doc.created_by === user?.id
```

On `canWrite = activeRole === 'owner' || activeRole === 'manager'`.

### UI — DocumentRow

- Icona `MoreVertical` (kebab menu) visible si l'usuari té permisos d'eliminació.
- Opció **"Treure última versió"**: deshabilitada si el document té 1 sola versió (`version_number === 1`).
- Opció **"Eliminar document complet"**: sempre disponible si l'usuari té `canDeleteAll`.
- Cada opció obre un Dialog de confirmació amb descripció de l'impacte.

### UI — DocumentVersionsModal

- Botó `Trash2` a la fila de la versió `idx === 0` (la més recent) si `canDeleteLatestVersion`.
- `canDeleteLatestVersion = versions.length > 1 && (canWrite || latestVersion.created_by === user.id)`

### Hooks React Query

| Hook | Invalidació |
|---|---|
| `useDeleteDocumentLatestVersion(tenantId)` | `documentsKeys.allDocs(tenantId)` + `documentsKeys.versions(documentId)` |
| `useDeleteDocumentAll(tenantId)` | `documentsKeys.allDocs(tenantId)` |

---

## Fitxers Afectats

| Fitxer | Canvi |
|---|---|
| `supabase/migrations/20260523000006_document_delete_rpcs.sql` | Nou: migration completa |
| `supabase/functions/process-deletion-queue/index.ts` | `DeletionPayload.bucket?` + `deleteFromSupabaseStorage(key, bucket)` |
| `apps/tenant-portal/src/types/database.types.ts` | Regenerat: `created_by` + nous RPCs |
| `supabase/functions/_shared/database.types.ts` | Còpia sincronitzada |
| `apps/tenant-portal/src/features/documents/api/documentsService.ts` | `deleteDocumentLatestVersion`, `deleteDocumentAll` |
| `apps/tenant-portal/src/features/documents/api/useDeleteDocumentLatestVersion.ts` | Nou hook |
| `apps/tenant-portal/src/features/documents/api/useDeleteDocumentAll.ts` | Nou hook |
| `apps/tenant-portal/src/features/documents/components/DocumentRow.tsx` | Dropdown delete + dialogs confirmació |
| `apps/tenant-portal/src/features/documents/components/DocumentVersionsModal.tsx` | Botó delete latest + dialog confirmació |
| `apps/tenant-portal/src/locales/ca/documents.json` | Claus i18n de supressió |

---

## Errors de Domini

Les RPCs llancen excepcions amb codis llegibles:

| Codi | Situació |
|---|---|
| `document_not_found` | L'ID no existeix a `data.documents` |
| `tenant_mismatch` | El `tenant_id` del document no coincideix amb el header `x-tenant-id` |
| `insufficient_permissions` | L'usuari no té rol suficient ni és el creador |
| `no_versions` | El document no té cap versió registrada |
| `last_version_cannot_be_deleted` | Intent d'eliminar l'única versió via `delete_document_latest_version` |
