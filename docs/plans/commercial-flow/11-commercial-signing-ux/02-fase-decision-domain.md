# Fase 2 — Domini durable de decisió comercial

> **Prioritat:** P0, cor de CF-28  
> **Tall desplegable:** sí, darrere feature flag  
> **Prerequisit:** fase 1  
> **No inclou:** nova UI d'enviament, portal ni DocuSeal

## Objectiu

Crear una única autoritat transaccional per a acceptar/refusar quote, agreement version i delivery note. Aquesta fase és additiva: els fluxos antics continuen mentre el nou domini entra per strangler.

## 2.1 Migració i schema

Crear la migració amb `supabase migration new commercial_decision_requests`.

### `data.commercial_decision_requests`

Columnes mínimes:

```text
id uuid PK
tenant_id uuid NOT NULL
client_account_contact_id uuid NOT NULL
commercial_document_id uuid NULL
agreement_version_id uuid NULL
purpose text NOT NULL                 acceptance | delivery_confirmation
status text NOT NULL                  open | accepted | declined | expired | revoked | superseded
active_provider text NULL             native | docuseal
snapshot_json jsonb NOT NULL
content_hash text NOT NULL
rendered_document_id uuid NOT NULL
document_version_id uuid NOT NULL
expires_at timestamptz NOT NULL
client_op_id uuid NOT NULL
created_by uuid NULL
decided_at timestamptz NULL
decided_via text NULL                 link | portal | office | presential | provider
created_at / updated_at timestamptz
```

Constraints:

- exactament un target no nul;
- `acceptance` només quote/amendment/agreement;
- `delivery_confirmation` només delivery note;
- `decided_at` obligatori en accepted/declined;
- `UNIQUE (tenant_id, client_op_id)`;
- únic parcial `commercial_document_id WHERE status='open'`;
- únic parcial `agreement_version_id WHERE status='open'`.

Índexs:

- `(tenant_id, client_account_contact_id, status, created_at DESC, id DESC)`;
- `(tenant_id, status, expires_at) WHERE status='open'`;
- FKs target/version/document/client indexades.

### `data.commercial_decision_deliveries`

```text
id uuid PK
tenant_id uuid NOT NULL
request_id uuid NOT NULL
channel text NOT NULL                  email | whatsapp | copy_link | portal | presential
recipient_contact_point_id uuid NULL
recipient_hash text NULL
recipient_masked text NULL
locale text NOT NULL
status text NOT NULL                   prepared | queued | sent | failed | revoked
idempotency_key text NOT NULL
email_log_id uuid NULL
error_code text NULL                   codi estable, mai missatge cru/PII
queued_at / sent_at / failed_at / created_at
```

Constraints/índexs:

- `UNIQUE (tenant_id, idempotency_key)`;
- `(request_id, created_at DESC)`;
- `(tenant_id, status, created_at)` per worker/ops.

No persistir el destinatari complet si es pot resoldre via `contact_point_id`; conservar només versió emmascarada + hash per auditoria/dedup.

### `data.commercial_decision_access_tokens`

```text
id uuid PK
tenant_id uuid NOT NULL
request_id uuid NOT NULL
delivery_id uuid NULL
token_hash text NOT NULL UNIQUE
status text NOT NULL                   active | revoked | expired | consumed
expires_at timestamptz NOT NULL
opened_at timestamptz NULL
last_opened_at timestamptz NULL
created_at timestamptz NOT NULL
revoked_at timestamptz NULL
```

Índex parcial `(token_hash) WHERE status='active'` i `(request_id, status)`.

El raw token només existeix en memòria/resposta de creació. Mai retorna en llistes ni logs.

### `data.commercial_decision_events`

Append-only:

```text
id uuid PK
tenant_id uuid NOT NULL
request_id uuid NOT NULL
event_type text NOT NULL
outcome text NULL
via text NULL
actor_id uuid NULL
portal_principal_id uuid NULL
signer_name text NULL
signer_email text NULL
signer_role text NULL
ip_address inet NULL
user_agent text NULL
content_hash text NOT NULL
provider text NULL
provider_submission_id uuid NULL
provider_session_id uuid NULL
reason text NULL
client_op_id uuid NULL
evidence jsonb NOT NULL DEFAULT '{}'
created_at timestamptz NOT NULL
```

- unique parcial/idempotent per `(request_id, client_op_id)` quan no nul;
- índex `(request_id, created_at)`;
- trigger/revokes que impedeixen UPDATE/DELETE a rols d'aplicació.

No duplicar raw tokens, signatures base64 ni payloads complets del provider dins `evidence`.

## 2.2 RLS i permisos

- RLS activa a totes quatre taules encara que `data` no sigui schema públic.
- `authenticated`: lectura tenant només via vistes/RPC necessàries; cap INSERT/UPDATE/DELETE directe.
- `anon`: cap privilegi.
- `service_role`: operació per Edge/workers.
- funcions internes a `data`, `SECURITY DEFINER`, `SET search_path=''`, EXECUTE revocat de PUBLIC/anon/authenticated excepte wrappers explícits.
- wrappers `api.*` validen `auth.uid`, tenant, rol i permisos abans de cridar la funció interna.

No usar `user_metadata`; l'autorització portal ve de la sessió BFF/grant resolta al servidor.

## 2.3 RPCs i funcions

### Crear

```text
api.create_commercial_decision_request(
  p_target_kind,
  p_target_id,
  p_expires_at,
  p_client_op_id
) -> request_id
```

Responsabilitats:

1. autorització tenant;
2. resoldre `formalization_mode` i target real;
3. exigir target emès i PDF/version id disponible;
4. construir snapshot immutable des del target;
5. validar `client_account_contact_id`;
6. supersede/reutilitzar segons CS-D10;
7. inserir request idempotent.

No crea email ni sessió provider.

### Lliurament/token

```text
api.create_commercial_decision_delivery(
  p_request_id,
  p_channel,
  p_contact_point_id,
  p_locale,
  p_client_op_id
) -> delivery_id + raw_token_once
```

Per email, només owner/manager o permís comercial equivalent. Per camp/presencial, respectar gates existents de commercial pricing/signing.

### Apply intern

```text
data.apply_commercial_decision_request(
  p_request_id,
  p_outcome,
  p_via,
  p_evidence,
  p_client_op_id,
  p_actor_id
) -> jsonb
```

Resultat estable:

```json
{
  "request_id": "uuid",
  "status": "accepted|declined|...",
  "applied": true,
  "already_decided": false
}
```

Algorisme:

1. lock request `FOR UPDATE`;
2. si no `open`, retornar estat existent;
3. lock target; projecte després si cal;
4. validar hash, status, expiry, supersede i tenant;
5. compare-and-set request;
6. aplicar target segons la taula d'outcomes;
7. inserir event/evidència;
8. recomputar autoritzat dins la mateixa transacció quan pertoqui;
9. inserir/intentar notificació idempotent o outbox; no enviar-la.

### Wrappers

- `api.apply_commercial_decision_office(...)`;
- `api.revoke_commercial_decision_request(...)`;
- `api.revoke_commercial_decision_delivery(...)`;
- `api.list_commercial_decision_requests(...)` keyset;
- funció service-only per resolver token;
- funció service-only per aplicar des de portal/provider.

## 2.4 Estats existents

### Firma nativa

Ampliar:

- `document_signing_sessions.status` amb `declined`;
- evidències amb event `declined`;
- `decline_signing_session_public` deixa de mapar client decline a `cancelled` quan hi ha request comercial;
- `cancelled` continua sent revocació/cancel·lació operativa.

### Agreement version

Ampliar:

- status `declined`;
- immutabilitat permet només `pending_signature → signed|declined`;
- event type `declined`;
- UI/listes reconeixen declined i permeten nova versió.

### Delivery note

Fer servir `status='rejected'` amb copy «Disputat» i actualitzar **tots**:

- `api.list_sales_delivery_notes_page`;
- `create_invoice_draft_from_delivery_notes`;
- helpers `delivery_note_is_invoiced`/balances si assumeixen `issued`;
- KPI/dashboard `to_invoice`;
- filtres/CTA de `DeliveryNotesList`;
- qualsevol RPC alternativa de factura/rectificació.

Test negatiu obligatori a cada porta, no només a la UI.

## 2.5 `separate_agreement`

Canviar la família de prepare (no només una definició antiga):

- quote/amendment `issued` o `accepted` permès si `formalization_mode='separate_agreement'`;
- snapshot/hash obligatori;
- quote no canvia a accepted durant prepare/send;
- finalitzar agreement signat aplica quote accepted atòmicament;
- decline agreement no accepta quote;
- preparar/firmar idempotent;
- documentar la substitució del gate as-built a [`../../commercial-agreements/pla-pressupost-contracte-acords.md`](../../commercial-agreements/pla-pressupost-contracte-acords.md).

No canviar `signed_quote`.

## 2.6 Strangler de `commercial_signing_intents`

1. Afegir `decision_request_id` nullable i indexat a `commercial_signing_intents`.
2. Flux antic sense flag: comportament actual.
3. Flux nou amb flag: crear request + intent lligat; trigger adapta signed/declined a apply nou.
4. Presencial deixa de fer doble apply client + trigger.
5. Migrar `api.commercial_signing_hub` per llegir request/provider refs.
6. Backfill només sessions actives que es poden mapar inequívocament.
7. Retirada de legacy en migració posterior, mai en aquesta fase.

Feature flag operativa, default false:

```text
tenants.settings.commercial.decision_requests_enabled
```

No exposar-la encara com a setting de producte.

## 2.7 Expiry, supersede i notificacions

- resolve/apply comproven expiry en temps real;
- job batch marca expirades amb `FOR UPDATE SKIP LOCKED`;
- emetre substitut/nova versió supersede request anterior i revoca tokens/sessions;
- notificació in-app outcome/caducitat idempotent per `request_id:event`;
- correu opcional a l'emissor queda en cua.

## Proves SQL obligatòries

1. CHECK xor target.
2. Unicitat open per target.
3. Idempotència mateixa key.
4. Carrera accept vs decline amb keys diferents: un sol outcome/event comercial.
5. Token raw no existeix a cap taula/log de test.
6. Quote accept/reject.
7. Agreement issued quote → prepare → sign → quote accepted.
8. Agreement decline → quote no accepted → nova versió possible.
9. DN decline → rejected/disputed → no list/CTA/RPC de factura.
10. Expirat, revocat, superseded i hash mismatch no apliquen.
11. Cross-tenant/anon/authenticated sense wrapper denegats.
12. Legacy flag off continua passant suites QT/CT.
13. Flag on passa hub i firma nativa sense doble apply.

## DoD

- [x] Schema/índexs/RLS/revokes creats.
- [x] Apply atòmic i carrera provada.
- [x] `separate_agreement` té una sola decisió client.
- [x] Decline diferent de cancel.
- [x] DN disputat no facturable per cap porta.
- [x] Strangler flag off/on verd.
- [x] Cap operació externa dins apply.
- [x] Types regenerats per tenant portal, Edge shared i public-portal.

## Rollback

- Desactivar feature flag: flux antic continua.
- No eliminar taules noves si hi ha requests: conservar com evidència.
- Revert funcional = deixar de crear requests noves, no esborrar outcomes aplicats.
