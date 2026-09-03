# Pla estratègic: Mòdul de Qualitat i Compliment ISO

**Data d'auditoria:** 2026-07-31  
**Abast inicial:** ISO 9001:2015, amb nucli extensible a ISO 14001 i ISO 45001.  
**Objectiu de producte:** evidència verificable i traçable per a auditories remotes, sense convertir el mòdul en una eina útil només per a empreses certificades.

## Decisió executiva

Es recomana una combinació de **D + C + A**, i descartar una migració global cap a permisos individuals com a prerequisit:

1. Crear un patró genèric de **Col·laborador Extern** per a auditor, gestoria, assessoria legal, mútua i casos futurs.
2. Dins d'aquest patró, oferir perfils prescrits (`external_auditor`, `external_accountant`, `external_advisor`) com a punt de partida, però no com a rols interns de `tenant_members`.
3. Afegir permisos granulars de Qualitat al RBAC intern existent, administrats per rol. Els col·laboradors externs reben capacitats explícites i limitades per cada concessió, no el rol intern `viewer` ni permisos ad-hoc sense contracte d'accés.
4. No fer ara una migració general a overrides per usuari. El valor no compensa el risc: la plataforma ja té RBAC per rol extensible, i l'accés extern té requisits de caducitat, abast i auditoria que un override individual no resol per si sol.

La regla de seguretat és: **cap usuari extern no entra a `tenant_members` com a substitut d'un membre intern**. Una concessió externa és una relació independent, temporal, revocable i auditada. Les polítiques RLS dels recursos de Qualitat han d'autoritzar per permís intern o per concessió externa activa i específica; mai només perquè la identitat existeixi en un tenant.

---

## 0. Auditoria del sistema actual

### Model multi-tenant i entitats disponibles

- `data.tenants` és l'organització; `data.sites` en delimita les seus. Les taules de negoci porten `tenant_id` i, quan correspon, `site_id`; `site_id IS NULL` significa recurs global del tenant.
- `data.profiles` estén `auth.users`. `data.tenant_members` relaciona perfil, tenant i opcionalment site. També permet que una mateixa identitat pertanyi a diversos tenants, però com a membre intern.
- `data.departments` forma una jerarquia organitzativa per tenant. Els membres poden tenir `department_id`; els projectes poden ser privats, de departament o de companyia mitjançant `data.project_members` i `visibility`.
- `data.projects` i `data.tasks` ja ofereixen una base per convertir accions correctives, plans de millora i preparació d'evidències en treball executable amb responsable i venciment.
- Els empleats viuen a `data.employees`, poden estar enllaçats a un perfil, un departament i un site. Ja existeixen `data.skills`, `data.skill_levels` i `data.employee_skills`, útils per no reinventar el catàleg de capacitats.
- El model no usa esquemes físics per tenant. Les taules privades viuen a `data.*`, les vistes/RPCs de client a `api.*`, i el tenant portal accedeix a `api.*` amb PostgREST.
- L'aïllament es fa amb RLS, `tenant_id`, el header `x-tenant-id` via `data.active_tenant_id()`, i claims JWT. `data.jwt_user_tenants()` llegeix primer el JWT i té fallback de base de dades. `data.audit_logs` ja és el ledger transversal de canvis de domini.

### Autenticació, rols i permisos: fet verificat

El rol base és **per membresia**, no per usuari amb overrides: `data.tenant_members.role` només admet `owner`, `manager`, `member` i `viewer`, globalment o per site. Aquest rol s'injecta al JWT i encara governa moltes polítiques RLS existents.

Hi ha també un RBAC granular, però no és un sistema de concessions individuals generals:

- Cada usuari rep al JWT un resultat per tenant a `app_metadata.user_permissions`.
- Aquest resultat es calcula a partir del seu **rol de membresia** i de `data.tenants.metadata.role_permissions`, una configuració per rol (`viewer`, `member`, `manager`). L'owner conserva `*`.
- `data.jwt_has_permission()` permet a nous mòduls fer RLS per permís i site. El portal manté el catàleg de claus a `apps/tenant-portal/src/lib/permissions.ts`.
- Hi ha excepcions locals, com `data.project_members` per projectes privats i ACL de nodes; no constitueixen un sistema d'overrides per usuari general i no s'han d'usar com a base de l'accés ISO transversal.

**Conclusió:** l'actual RBAC sí que suporta permisos granulars per mòdul, però són permisos efectius per usuari derivats de rols, no permisos configurables individualment. Això confirma que no hi ha un bloqueig per començar Qualitat, però també que no s'ha de modelar un auditor com un `viewer` convencional.

### Gestió documental actual

- El DMS té `data.documents`, carpetes i `data.document_versions`; cada versió té número correlatiu, origen d'emmagatzematge, creador i data. Les vistes de documents actius resolen la versió més alta.
- L'accés als documents es governa per tenant/site i `required_permissions`, i l'escriptura ordinària està restringida principalment a `owner`/`manager`.
- Ja existeixen dates de vigència, caducitat i renovació, arxiu tou (`is_archived`) i auditoria de creació, versió, arxiu i eliminació.
- Existeix `approval_status` (`none`, `pending`, `approved`, `rejected`), `approved_by` i `approved_at`, connectat al motor d'automatització. Les aprovacions poden tenir destinatari individual o per rol.

**Límit actual:** l'estat d'aprovació és del document, no de la versió concreta; no hi ha l'estat ISO complet `draft/review/approved/obsolete`, ni registre de transicions, ni llista d'aprovadors per document, ni regla que fixi quina versió és la publicada. Aquesta distinció és imprescindible per assegurar que un auditor veu exactament la versió vigent i la seva traçabilitat.

### Decisions de tancament: aprovació, activació i accés extern

#### 1. Una font de veritat per a documents Quality; `approval_status` es conserva com a projecció compatible

`data.documents.approval_status` **no es depreca ni se substitueix**: és un contracte ja consumit per `api.create_automation_pending_approval_service(...)` i `api.resolve_automation_approval(...)`. Per a un document sense fila a `data.quality_document_controls`, conserva exactament el comportament actual. Per a un document Quality, la font de veritat és la fila de `data.quality_document_controls`, amb `publication_status`, `approved_document_version_id` i els events version-aware de `data.quality_document_publication_events`.

El camp existent passa a ser una projecció compatible, actualitzada dins de la mateixa transacció que el control Quality:

| Transició Quality | `documents.approval_status` projectat | Efecte |
|---|---|---|
| versió nova `draft` | `none` | no hi ha aprovació en curs |
| `draft -> in_review` | `pending` | la versió candidata queda vinculada a l'aprovació d'automatització |
| `in_review -> approved` | `approved` | es fixa `approved_document_version_id` i es publica només aquella versió |
| resolució `rejected` | `rejected` i retorn a `draft` | el resultat queda visible fins que es crea o se sotmet una nova revisió |
| `approved -> obsolete` | `approved` | la versió històrica continua aprovada, però deixa de ser la publicada |

Es crea l'únic escriptor `data.apply_quality_document_transition(...)`, cridat per les RPCs `api.submit_quality_document_for_review(...)`, `api.transition_quality_document_control(...)` i, quan el `context_preview` porta `document_id` Quality, per les versions modificades de `api.create_automation_pending_approval_service(...)` i `api.resolve_automation_approval(...)`. Aquest escriptor actualitza control, versió publicada, `documents.approval_status`, `approved_by`, `approved_at` i l'event immutable en una sola transacció.

Dos triggers de protecció impediran la divergència: `data.trg_guard_quality_document_approval_projection()` rebutja canvis directes a `data.documents.approval_status` si existeix el control Quality, i `data.trg_guard_quality_document_control_transition()` rebutja canvis directes als camps de cicle de vida del control. Només `data.apply_quality_document_transition(...)` activa el context transaccional intern permès. Això conserva totes les automatitzacions i notificacions existents: els documents no Quality continuen sent actualitzats pels dos RPCs d'automatització actuals, i els Quality hi continuen apareixent amb els mateixos quatre valors compatibles.

#### 2. Activació per tenant: feature flag existent, no un entitlement nou

El mòdul és opt-in tècnic amb la clau `quality_enabled` de `data.feature_flags`. Es reutilitzen `data.tenant_feature_overrides` i `data.is_feature_enabled(tenant_id, 'quality_enabled')`; la flag es crea desactivada i cada tenant habilitat rep `override_status = true`. `api.get_tenant_features()` retorna també `quality_enabled`, i el hook existent `useTenantFeatures()` l'exposa al portal.

Les noves RLS i RPCs Quality han d'exigir `data.is_feature_enabled(tenant_id, 'quality_enabled')` a més del permís o grant corresponent. Les consultes/accions del mòdul retornen `feature_disabled: quality_enabled` amb `42501` quan no està actiu. Que les taules i migracions existeixin no concedeix cap dada ni capacitat als tenants no activats.

El menú Quality queda **ocult completament** quan `quality_enabled` és fals, igual que el menú de Recruitment condicionat a `features?.recruitment_enabled` a `AppLayout`. Les rutes directes mostren només l'estat desactivat, sense carregar dades Quality ni oferir una CTA comercial dins del producte. La decisió pendent de negoci és si l'habilitació la concedeix un pla, un add-on o suport: avui `data.plans.features_jsonb` existeix, però la implementació vigent de `data.is_feature_enabled()` resol la flag global i l'override per tenant; no s'ha de declarar que el pla l'activa fins que Producte decideixi i s'estengui explícitament aquesta funció.

#### 3. Els permisos Quality ja tenen editor owner; només cal ampliar-ne el catàleg

Existeix una UI efectiva per a l'owner a `apps/tenant-portal/src/pages/settings/PermissionsPage.tsx`: renderitza `RolePermissionsEditor`, que llegeix `api.get_tenant_role_permissions(...)` i desa via `api.update_tenant_role_permissions(...)` a través de `useRolePermissions`. Els rols editables són `viewer`, `member` i `manager`; l'owner conserva `*`. Per tant, un tenant ja pot decidir que `member` tingui lectura i no aprovació sense intervenció de suport.

No cal una pantalla nova ni un canvi estructural de la matriu. El canvi mínim és afegir les claus Quality a `PermissionKey`, `ALL_PERMISSION_KEYS`, permisos base i dependències a `apps/tenant-portal/src/lib/permissions.ts`; incloure el bloc estàtic `{ key: 'quality', permissions: [...] }` a `PERMISSION_GROUPS` de `RolePermissionsEditor.tsx`; i afegir les mateixes claus a la llista de validació de `api.update_tenant_role_permissions(...)` a `20260511000006_role_permissions_rpc.sql` o a la seva substitució vigent. El bloc es pot ocultar visualment si `quality_enabled` és fals, però la validació de servidor continua sent la font d'autoritat.

#### 4. Flux concret de l'auditor: identitat autenticada, selector separat i portal restringit

La invitació és una operació owner/manager mitjançant una Edge Function nova `invite-external-collaborator`, cridada des d'una RPC transaccional `api.create_external_access_invitation(...)`. Aquesta crea `data.external_collaborators`, `data.external_access_invitations` i el futur `data.external_access_grants`/scopes, registra `EXTERNAL_ACCESS_INVITED` i encola l'email. La invitació no crea mai `data.tenant_members`.

- Si l'email encara no té `auth.users`, la funció usa `auth.admin.inviteUserByEmail` i l'enllaç porta a `/external-access/accept`. En acceptar-lo, la ruta resol la sessió, vincula/crea `data.profiles` i associa el `profile_id` a `data.external_collaborators`; llavors activa el grant precreat. No es permet crear un compte arbitrari des del formulari de login.
- Si l'email ja té `auth.users`, no es recrea ni es modifica el compte: la funció vincula el perfil existent al col·laborador i activa un grant addicional. Això permet una mateixa auditora per a molts tenants.
- El mètode recomanat és magic link/passwordless. El portal ja implementa `supabase.auth.signInWithOtp({ shouldCreateUser: false })` per a comptes existents; és adequat a un perfil que entra esporàdicament i evita gestionar una contrasenya dedicada. La primera invitació usa el link d'acceptació; els accessos posteriors usen magic link. La contrasenya ordinària roman opcional, no el flux principal.

No s'estén `data.jwt_user_tenants()` ni `useTenants()`: tots dos es basen en `data.tenant_members`, i incloure-hi grants externs faria que polítiques històriques els tractessin erròniament com a membres interns. Es crea `api.list_external_access_tenants()` que retorna només grants actius de `auth.uid()` amb `tenant_id`, nom, slug, perfil, expiració i capacitats resumides. `ExternalAccessContext` combina aquesta resposta amb `useTenants()` per a un únic selector visual, però cada entrada porta `access_kind: 'internal' | 'external'`; l'entrada externa no té `role`, sites interns ni vista de "totes les organitzacions". Seleccionar-la fixa només `x-tenant-id` i `external_grant_id` per a les RPCs externes, sense claims nous.

L'auditor usa la mateixa SPA i domini, però sota `/auditor/*` amb `AuditorLayout`, no `AppLayout`: només carrega la shell, rutes i hooks de lectura Quality autoritzats. És més barat que una altra app/subdomini i redueix la superfície accidental d'UI privilegiada; la frontera de seguretat segueix sent RLS/RPC, no el routing client. Les rutes internes rebutgen explícitament sessions `access_kind = 'external'`.

Per a revocació en calent, totes les RPCs de l'auditor comencen amb `data.require_external_access(p_tenant_id, p_grant_id, p_action)`, que verifica grant, data, revocació i scope en base de dades. Retorna `42501` amb `external_access_revoked` o `external_access_expired`, no un 403 indiferenciat. `ExternalAccessContext` crida `api.get_external_access_context(p_grant_id)` en l'entrada, en focus i cada 60 segons; en rebre aquests codis neteja la selecció, invalida la cache, mostra el missatge traduït de revocació i redirigeix a `/auditor/access`. La mateixa validació en cada crida talla l'accés immediatament, fins i tot abans del següent heartbeat.

#### 5. Llistats externs filtrats en SQL abans de retornar metadades

Un grant per carpeta no pot usar `api.active_documents`, perquè aquesta vista hereta la regla de membre intern `data.user_can_read_doc_resource(...)`. Es crea el helper set-based `data.external_visible_quality_document_ids(p_tenant_id uuid, p_grant_id uuid, p_action text) RETURNS TABLE(document_id uuid)`, `STABLE SECURITY DEFINER` i amb `search_path` fixat. El helper primer crida `data.require_external_access(...)`; després resol, en una sola consulta, el conjunt de documents del tenant autoritzats per:

- scope `module` amb `resource_type = 'quality.documents'`, que inclou tots els documents Quality elegibles;
- scope `document`, que inclou només aquell `document_id`;
- scope `document_folder`, que calcula amb un CTE recursiu els descendents de cada carpeta concedida i inclou els documents d'aquell arbre.

Els tres conjunts s'uneixen amb `UNION`/`SELECT DISTINCT`; no hi ha una comprovació per document. La lectura es publica només amb `api.list_external_quality_documents(p_tenant_id, p_grant_id, p_cursor, p_limit)`, una RPC `SECURITY DEFINER` que fa `JOIN data.external_visible_quality_document_ids(...)` contra `data.documents`, el control Quality i **només** `approved_document_version_id`. Aquesta és la consulta que consumeix la llista de l'auditor; no es concedeix `SELECT` sobre `api.documents`, `api.active_documents`, `api.document_versions` ni `api.document_folders` a la shell externa.

Per navegar, `api.list_external_quality_document_folders(...)` deriva les carpetes directament dels IDs visibles i dels seus ancestres necessaris per al breadcrumb. No retorna germans, comptadors ni metadades d'una carpeta sense document visible. L'obertura o descàrrega individual continua cridant `data.require_external_access(...)` amb el document/version concret, de manera que un grant revocat entre el llistat i el clic no es pot aprofitar.

### Plantilles actuals

- `data.document_templates` separa plantilles de plataforma (`tenant_id IS NULL`, `is_platform_default = true`) i de tenant. Per a cada plantilla existeixen locals/fitxers i un esquema de variables.
- Un tenant pot clonar una plantilla mitjançant `api.create_document_template`; el clone conserva `cloned_from_id`, i pot heretar configuració de blocs.
- Les plantilles tenen activació i auditoria, i permeten segmentar per arquetip i sector.

**Límit actual:** `cloned_from_id` conserva l'origen lògic, però no hi ha una revisió immutable de plantilla ni un snapshot de la revisió que el tenant va adoptar. Per tant, no és possible detectar de manera fiable que una plantilla ISO de plataforma ha canviat respecte del clone ni saber quina versió concreta va originar un document final.

### Accés extern existent

No hi ha un patró d'identitat externa autenticada amb abast multi-mòdul. Hi ha dos precedents que no s'han de confondre amb aquest patró:

- `document_share_links`: URLs públiques temporals i revocables per a una versió concreta, amb comptador i darrer accés. Són adequades per expedir un dossier puntual, no per a una auditoria interactiva identificada.
- L'expedició d'auditoria del DMS agrupa documents per compartir-los, però tampoc aporta autorització per persona, comentaris, troballes ni visibilitat estructurada dels registres.

---

## 1. Arquitectura de permisos recomanada

### Avaluació de les opcions

| Opció | Valor | Limitació | Decisió |
|---|---|---|---|
| A. Granularitzar `viewer` | Reutilitza `jwt_has_permission()` i permet permisos interns de Qualitat | Un `viewer` és membre intern; no aporta caducitat, abast per recurs ni separació RGPD | Adoptar només per als permisos interns de Qualitat |
| B. Overrides per usuari | Expressiu per excepcions internes | Requereix canviar el càlcul de claims, editor, propagació de token i moltes RLS; no resol per si mateix invitacions, revocació en temps real ni activitat externa | No fer en aquesta iniciativa; reavaluar com a ADR transversal si apareixen més casos interns |
| C. Rol extern dedicat | Clar per a l'auditor, senzill d'explicar | Només un rol fix no cobreix gestoria ni abast per recurs; si entra a `tenant_members`, hereta pressupòsits interns | Adoptar-lo com a perfil predefinit dins el patró D, no com a rol intern |
| D. Col·laborador extern genèric | Cobreix multi-tenant, abast, nivell, caducitat, revocació i registre | És més modelatge inicial i obliga a una capa RLS explícita | **Arquitectura principal recomanada** |

### Disseny del Col·laborador Extern

Una identitat `data.profiles` pot tenir moltes concessions independents, una per tenant i per període. Això permet que la mateixa auditora treballi per diversos clients sense que cap consulta d'un client pugui obrir dades d'un altre.

**Entitats proposades**

- `data.external_collaborators`: perfil extern de negoci sobre `profiles`; tipus (`auditor`, `accountant`, `advisor`, `legal`, `other`), organització i dades de consentiment/identificació mínimes.
- `data.external_access_invitations`: invitació emesa per un owner/manager, destinatari, perfil proposat, data d'expiració, acceptació, cancel·lació i emissor.
- `data.external_access_grants`: concessió efectiva per `tenant_id` + col·laborador, amb `starts_at`, `expires_at`, `revoked_at`, motiu, qui l'ha aprovada i estat. Una auditora amb tres clients tindrà tres files, no una membresia global.
- `data.external_access_scopes`: fills de la concessió. Scope de `module`, `document_folder`, `document`, `quality_audit`, `quality_nonconformity`, `quality_management_review` o `site`; acció permesa `read`, `comment`, `create_finding`, `create_nonconformity`. No admet `update_document`, `approve_document` ni permisos administratius.
- `data.external_access_events`: ledger append-only de login, selecció de tenant, lectura de document/versió, descàrrega, comentari, creació o canvi de troballa, intent denegat, invitació, caducitat i revocació. Ha d'enllaçar també amb `data.audit_logs` per a la timeline unificada.

**Enforcement RLS i revocació**

- Les noves polítiques de Qualitat han de concedir accés si el permís intern ho permet **o** si una funció `data.external_access_allows(...)` confirma en base de dades que la concessió està activa, no ha expirat/revocat i cobreix el recurs i l'acció.
- No n'hi ha prou amb posar grants externs al JWT: una revocació ha de tallar l'accés immediatament, no al següent refresh de token. El JWT només pot portar una pista d'UX; la decisió RLS externa ha de validar la concessió en viu.
- Cada taula de Qualitat ha de portar `tenant_id`; els helpers han de validar que tot recurs scoped pertany al mateix tenant que el grant. El header actiu és un filtre de context, mai una prova d'autorització.
- Les operacions sensibles s'han d'exposar amb RPCs transaccionals, validant la capacitat concreta. L'auditor pot crear observacions, troballes o no conformitats externes, però no editar `documents`, `document_versions`, controls de publicació ni evidències del tenant.
- Definir retenció per a `external_access_events`, minimitzar IP/user-agent segons política RGPD, mostrar-la en el registre d'activitat i permetre exportar el dossier de traçabilitat al tenant.

**Permisos interns nous**

Afegir al registre de permisos, migració de validació i editor de rols claus com: `quality.documents.view/manage/approve`, `quality.audits.view/manage/execute`, `quality.nonconformities.view/manage/close`, `quality.risks.view/manage`, `quality.objectives.view/manage`, `quality.competence.view/manage`, `quality.management_review.view/manage` i `quality.external_access.manage`. Les dependències han de ser explícites i el tenant pot decidir a quin rol intern les concedeix.

---

## 2. Model de dades integrat

### Nucli normatiu i documental

| Entitat | Finalitat i enllaços |
|---|---|
| `quality_standards`, `quality_standard_clauses` | Catàleg de plataforma, versionat per edició de norma. Ex.: ISO 9001:2015 clàusules 4-10. És extensible afegint 14001/45001 sense modificar les relacions de negoci. |
| `quality_document_controls` | Un control per `document_id`; propietari (`employee_id` o `profile_id`), `publication_status` canònic, `approved_document_version_id`, propera revisió, periodicitat, criticitat, aplicabilitat per site i data d'obsolescència. Complementa `documents`, no el duplica; `documents.approval_status` és la projecció compatible definida a la decisió 1. |
| `quality_document_clause_mappings` | Relació N:M entre control documental i clàusula de norma; permet una evidència per múltiples clàusules. |
| `quality_document_approvers` | Matriu d'aprovació definida per document/control: usuari o rol intern, ordre i obligatorietat. No admet un col·laborador extern com aprovador. |
| `quality_document_publication_events` | Ledger immutable, version-aware: enviat a revisió, retornat, aprovat, publicat, substituït, obsolet. Referència explícita a `document_version_id`, actor i comentari. |

L'estat publicat ISO serà `draft -> in_review -> approved -> obsolete`. `rejected` retorna a `draft`. `approved` ha de fixar `approved_document_version_id`; una pujada posterior crea una nova revisió en esborrany i no altera la versió vigent. L'arxiu DMS (`is_archived`) és diferent d'obsolescència ISO: arxivar és operatiu, obsolet és una decisió de control documental que preserva consulta històrica.

### Procediments, no conformitats i CAPA

| Entitat | Finalitat i enllaços |
|---|---|
| `quality_processes` | Mapa de processos del tenant, propietari, site/departament, entrades, sortides i indicadors. És l'ancoratge per riscos, competències, auditories i documents. |
| `quality_nonconformities` | Registre mestre: origen (`internal_audit`, `external_audit`, `customer_incident`, `checklist`, `process`, `other`), severitat, descripció, procés, clàusules, responsable, venciment i estat. Enllaça opcionalment amb auditoria, checklist item, contacte, projecte o document. |
| `quality_capa_actions` | Accions de contenció, correcció, causa arrel, correctiva, preventiva i verificació d'eficàcia; cada acció pot crear/enllaçar una `task` existent per executar-la. |
| `quality_evidence_links` | Evidència polimòrfica i tipada: `document_version`, document, tasca, checklist run/item, projecte, work log, signatura, URL externa o comentari. Guarda una referència immutable quan sigui una versió documental. |

No es tanquen no conformitats amb una tasca només marcada com feta: cal causa arrel, acció aplicada, evidència, verificació d'eficàcia, verificador diferent del responsable quan el risc ho exigeixi, i event d'auditoria. Les observacions d'un auditor extern es registren primer amb actor extern i es poden elevar a no conformitat sense perdre-ne procedència.

### Auditories i revisió per la direcció

| Entitat | Finalitat i enllaços |
|---|---|
| `quality_audit_programs`, `quality_audits` | Programa anual i cada auditoria: abast, criteris/normes, processos, sites, pla, equip auditor, dates, estat i informe. L'auditor pot ser perfil intern o col·laborador extern autoritzat. |
| `quality_audit_checklists`, `quality_audit_checklist_items` | Checklists ISO específics. Poden reutilitzar el motor actual de checklist publicat per a l'execució mòbil, mantenint un snapshot de la versió aplicada. |
| `quality_audit_findings` | Troballes, observacions i no conformitats amb clàusula, evidències, resposta del tenant i link a `quality_nonconformities` quan correspongui. |
| `quality_management_reviews`, `quality_management_review_inputs`, `quality_management_review_decisions` | Convocatòria, participants, període, inputs obligatoris ISO 9001, decisions, accions i evidències. Enllaç a objectius, KPIs, riscos, NC/CAPA i resultats d'auditoria. |

El motor de `checklist_runs` existent és una bona base per a execució offline/tablet i ja té fallades i follow-up tasks. El mòdul ISO hi ha d'afegir la semàntica d'auditoria, les clàusules i la traçabilitat CAPA, en lloc de clonar tota la infraestructura de formularis.

### Riscos, objectius i competència

| Entitat | Finalitat i enllaços |
|---|---|
| `quality_risks`, `quality_risk_assessments`, `quality_risk_treatments` | Risc o oportunitat per procés/site. Cada avaluació és històrica, amb probabilitat i impacte en escala configurada, puntuació calculada $R = P \times I$, nivell/semàfor, controls, responsable, revisió i accions. La UI renderitza la matriu des de les escales, no d'un color guardat arbitràriament. |
| `quality_objectives`, `quality_kpi_definitions`, `quality_kpi_measurements` | Objectius amb responsable, termini, meta i clàusula/procés; definicions de KPI amb unitat, font i freqüència; mesures temporals immutables per tendència i dashboard. |
| `quality_competency_requirements` | Defineix quines habilitats/procediments requereix cada procés o rol operatiu; referencia `data.skills` quan és una habilitat existent. |
| `quality_employee_competencies`, `quality_training_records` | Matriu empleat x habilitat/procés amb estat `capable`, `in_training`, `can_train`, avaluador, dates, evidència i formació realitzada/planificada. Conserva `employee_skills` com a catàleg de talent; la capa Quality és l'evidència ISO i no hi barreja dades mèdiques. |

El mòdul de `compliance_requirement_types` i certificacions d'empleat continua sent compliment legal/tècnic individual. Es pot enllaçar com a evidència de formació o competència, però no s'ha de reanomenar ni absorbir com si fos el SGC ISO 9001.

### Requisits transversals de totes les taules noves

- `tenant_id NOT NULL`, FK al tenant i validacions de coherència de tenant/site/procés/empleat/document en triggers.
- `created_at`, `updated_at`, actor i, per als canvis de cicle de vida, triggers a `data.audit_logs` amb accions descriptives: `QUALITY_DOCUMENT_APPROVED`, `NONCONFORMITY_OPENED`, `CAPA_EFFECTIVENESS_VERIFIED`, `EXTERNAL_ACCESS_REVOKED`, etc.
- Vistes `api.*` amb `security_invoker = true`; el tenant portal no consulta `data.*` directament.
- RPCs per transicions multi-taula, amb control d'autorització, auditoria i evidències dins la mateixa transacció. Les notificacions i recordatoris passen pel patró PGMQ/RPC del repositori.
- Índexs inicials per `(tenant_id, status, due_at)`, `(tenant_id, process_id)`, `(tenant_id, reviewed_at)` i les consultes del dashboard; evitar JSONB com a font principal de filtre operatiu.

---

## 3. Biblioteca de plantilles ISO 9001

### Reutilització del sistema existent

La biblioteca ha d'usar `data.document_templates` i les seves locals, amb categoria `iso_9001` i metadades d'aplicabilitat. El catàleg de plataforma ha d'incloure, com a mínim:

- Política i objectius de qualitat.
- Manual de qualitat o mapa del SGC.
- Mapa i fitxes de processos.
- Control de la informació documentada.
- Matriu de riscos i oportunitats.
- Programa, pla, checklist i informe d'auditoria interna.
- Registre de no conformitats, CAPA i verificació d'eficàcia.
- Acta de revisió per la direcció.
- Pla/matriu de competències i formació.
- Fitxes de KPI i quadre de seguiment.

### Gap a resoldre: revisions i procedència

Les plantilles ISO no poden dependre només de `cloned_from_id`. Cal introduir un model de revisió immutable:

- `document_template_revisions`: revisió numerada, estat `draft/published/superseded`, fitxers/locals i checksum o snapshot de la definició publicada.
- El template existent actua com a capçalera lògica; una revisió publicada no es modifica. Una actualització de plataforma crea una nova revisió, no sobreescriu l'anterior.
- `quality_template_profiles` mapeja cada revisió a estàndard, clàusules, tipus de document i dades d'onboarding requerides.
- `quality_document_template_origins` enllaça el control documental del tenant amb template, revisió d'origen i data d'adopció. Quan el tenant edita el document, el vincle continua informant de la base, però no implica actualització automàtica.
- Una projecció de "canvis disponibles" compara la revisió d'origen adoptada amb l'última revisió publicada de la plantilla de plataforma. Mostra diff/resum i permet crear una revisió de treball al tenant; mai substitueix automàticament un document aprovat.

---

## 4. Roadmap d'execució

La petició anomena Fases 0-4 i una Fase 5 opcional; per respectar l'ordre de dependències, el roadmap té cinc fases obligatòries de 0 a 4 i una sisena opcional. No s'inicia implementació funcional fins tancar la Fase 0.

### Fase 0: arquitectura de permisos i contracte de dades

**Objectiu.** Tancar l'ADR de RBAC extern, el model canònic del SGC, l'estratègia de migració i les regles RLS/auditoria abans de crear pantalles.

**Principals superfícies.** Migracions noves de Quality/External Access; `quality_enabled` a `data.feature_flags`/`data.tenant_feature_overrides`; contracte de permisos a `apps/tenant-portal/src/lib/permissions.ts` i bloc Quality de `RolePermissionsEditor`; helpers RLS; tipus generats; ADR i diagrama d'entitats a `docs/plans/ISO/`.

**Decisions que han de quedar aprovades.** Taxonomia de permisos, scopes externs permesos, semàntica de revocació immediata, retenció de logs, escala de risc, transicions de document, ownership de processos i si el catàleg de clàusules és gestionat per plataforma.

**Fet quan.** Existeixen ADR signat, ERD, matriu d'autorització interna/externa, casos RLS de multi-tenant/revocació/abast i pla de migració. Els tipus de base de dades es regeneren després de les migracions. Sense aquests artefactes, no s'obre Fase 1.

### Fase 1: motor documental ISO i biblioteca de plantilles

**Objectiu.** Convertir el DMS en control documental certificat, mantenint utilitat per a qualsevol tenant.

**Principals superfícies.** `documents`, `document_versions`, controls i events Quality; `data.apply_quality_document_transition(...)` i integració compatible amb `api.create_automation_pending_approval_service(...)`/`api.resolve_automation_approval(...)`; revisions de plantilles; `api.*` views/RPCs; DMS del tenant portal; configuració de flux d'aprovació; locals CA/ES/EN; tests SQL de transicions i RLS.

**Funcionalitat.** Metadades ISO, processos/clàusules, propietari, revisió programada, aprovació per versió, publicació i obsolescència; biblioteca ISO 9001; clone amb revisió d'origen i alerta de canvi disponible.

**Fet quan.** Un responsable pot adoptar una plantilla, publicar una versió després d'aprovació, substituir-la sense perdre la versió vigent anterior i demostrar a un auditor l'origen, totes les transicions, aprovador i clàusules aplicables.

### Fase 2: operació del SGC i auditoria interna mobile-first

**Objectiu.** Cobrir el bucle operatiu de millora contínua: troballa, CAPA, risc, objectiu, competència i auditoria interna de camp.

**Principals superfícies.** Taules `quality_*` de NC/CAPA, riscos, objectius/KPI, processos, competència i auditories; integració amb `projects`, `tasks`, `employees`, `skills`, DMS, `checklist_runs` i timeline; pàgines Quality del tenant portal; cues de recordatori.

**UX mobile-first.** L'execució de checklist ha de prioritzar una columna, targets tàctils grans, ús offline/idempotent del motor de runs, adjuntar evidències des de càmera/fitxer, resum de fallades i creació de troballa sense obligar a navegar a un formulari administratiu. La configuració de plantilles, riscos i KPIs pot ser desktop-first.

**Fet quan.** Una auditoria interna feta en una tablet genera troballes, NC/CAPA, tasques i evidències; una NC no es tanca sense verificació d'eficàcia; la matriu de riscos i la de polivalència es poden consultar per procés/site; els KPIs conserven la seva sèrie temporal.

### Fase 3: accés extern unificat

**Objectiu.** Posar en producció el patró de col·laborador extern, primer per auditors ISO i després per gestories, sense relaxar l'aïllament actual.

**Principals superfícies.** `external_collaborators`, invitacions, grants, scopes i events; `invite-external-collaborator`; `api.list_external_access_tenants()` i `api.get_external_access_context(...)`; `ExternalAccessContext`; helpers RLS; flux d'invitació/acceptació/revocació; pantalles de gestió de concessions i log; autenticació i selecció de tenant; proves de seguretat SQL i E2E.

**Funcionalitat.** Invitació temporal, concessió per tenant, abast per mòdul/carpeta/document/auditoria, lectura/comentari/troballa, revocació instantània, expiració automàtica i activity log exportable. El perfil d'auditor no pot alterar cap document ni tancar la seva pròpia no conformitat.

**Fet quan.** La mateixa auditora pot entrar a dos tenants autoritzats, només veu cada dossier assignat, deixa una observació amb identitat i data, i perd l'accés al moment de revocar el grant fins i tot amb una sessió JWT encara vàlida.

### Fase 4: portal de l'auditor i dashboard de compliment

**Objectiu.** Fer realment auditable el SGC remotament i convertir les dades en priorització operativa per al tenant.

**Principals superfícies.** `api.list_external_quality_documents(...)`, `api.list_external_quality_document_folders(...)` i `data.external_visible_quality_document_ids(...)`; portal `/auditor/*` amb `AuditorLayout`; dashboard Quality; revisió per la direcció; export de dossier; observabilitat de consultes i activitat externa.

**Funcionalitat.** Vista d'auditoria per estàndard/clàusula, documents vigents i obsolets, traçabilitat de versions, CAPA obertes/vencudes, riscos alts, objectius/KPIs, competència requerida i estat de preparació. La revisió per la direcció consolida inputs i deixa decisions/accions vinculades.

**Fet quan.** Un auditor extern pot preparar una auditoria remota sense suport manual del tenant, el tenant pot exportar el dossier i l'equip directiu pot veure els buits que impedeixen considerar el sistema preparat. El dashboard mostra "evidència disponible", no una afirmació automàtica de certificació ISO.

### Fase 5 opcional: onboarding per a tenants que parteixen de zero

**Objectiu.** Reduir el temps fins al primer SGC usable sense fabricar una certificació fictícia.

**Principals superfícies.** Wizard al tenant portal, plantilles ISO, `quality_processes`, orquestració de clonat via RPC/cua i revisió humana obligatòria abans de publicar.

**Funcionalitat.** Recollir missió, visió, abast, sites, processos, responsables i riscos inicials; proposar un esquelet del Manual de Qualitat, crear el mapa de processos i clonar les plantilles rellevants amb estat `draft`.

**Fet quan.** El tenant obté una estructura inicial editable amb procedència de plantilles, cap document es publica automàticament i el wizard deixa clar quines dades/evidències encara ha d'aportar l'organització.

---

## Controls de qualitat de l'entrega

- Cada migració que toqui `data.*`, `api.*` o RPCs exposades regenera `apps/tenant-portal/src/types/database.types.ts` i `supabase/functions/_shared/database.types.ts` amb la comanda oficial del repositori.
- Tots els textos visibles del tenant portal usen `react-i18next` amb clau i fallback en català.
- Proves SQL obligatòries: aïllament per tenant i site, flag `quality_enabled` desactivada, cap accés després de caducitat/revocació, scope per document/carpeta/mòdul en un sol llistat, absència de metadades fora d'scope, denegació d'edició documental externa, sincronització no divergent de `approval_status`, transicions documentals invàlides, i integritat cross-tenant de cada FK Quality.
- Proves E2E obligatòries: auditoria interna en mòbil/tablet, invitació/acceptació d'auditor, canvi entre dos tenants, lectura auditada, creació de troballa, revocació durant sessió i export del dossier.
- Les mètriques de preparació no s'han de presentar com a certificació ni com a assessorament normatiu: indiquen cobertura d'evidència i elements pendents contra l'estàndard configurat.