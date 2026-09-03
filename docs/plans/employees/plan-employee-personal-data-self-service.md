# Pla executable - Autoservei de dades personals de l'empleat (EHR-3.4)

> **Data:** 2026-07-21  
> **Estat:** pla executable - pendent d'implementació  
> **Depèn de:** EHR-3 perfil privat, portal d'empleat i notificacions/cues  
> **Pla pare:** [`EXECUTION.md`](./EXECUTION.md) i [`plan-employees-hr-core-v2.md`](./plan-employees-hr-core-v2.md)  
> **Principi:** l'empleat és responsable de mantenir les seves dades de contacte, però no les modifica directament: proposa un canvi que RRHH autoritzat revisa i resol.

---

## 1. Objectiu i decisió de canal

L'empleat ha de poder consultar les seves dades personals de contacte, detectar errors i proposar-ne la correcció. Un usuari del tenant amb permís explícit ha de revisar cada proposta abans d'aplicar-la.

**Canal escollit: espai de dades personals sobre el portal d'empleat autenticat.** No es crearà un formulari públic que llegeixi o modifiqui PII mitjançant un magic link.

| Cas | Accés |
|---|---|
| Empleat que ja té portal | Pot obrir la secció de dades personals si la seva sessió té capacitat `personal_data`. |
| Empleat sense portal | RRHH emet un accés temporal exclusiu `personal_data`; no dona calendari, fitxatges, documents ni altres superfícies. |
| Enllaç enviat per correu | Només inicia el flux de sessió segura amb PIN o confirma la possessió d'un email nou. Mai retorna PII ni accepta un patch directament. |

El token actual del portal és una credencial bearer. Per a PII, la seva possessió sola no és suficient: cal token individual no compartit, PIN obligatori, sessió curta i reautenticació abans d'enviar una proposta.

---

## 2. Abast MVP

### 2.1 Camps consultables i corregibles

Tots viuen a `data.employee_private_profiles` i només es poden enviar dins un patch de camps permesos:

- `personal_email`
- `personal_phone`
- `address`, `postal_code`, `city`, `country_code`
- `emergency_contact_name`, `emergency_contact_phone`, `emergency_contact_relationship`

### 2.2 Exclosos

- `document_type`, `document_number`, `social_security_number`, `birth_date`, `nationality_code`.
- IBAN, compensació, contracte, categoria, conveni, jornada i dates laborals.
- Salut, discapacitat, adaptacions i reconeixements mèdics.
- Foto, skills, certificacions, experiència, `metadata` i camps lliures.
- Actualització de `employees.email`, `auth.users`, `profiles` o `tenant_members`.

Els camps exclosos requeriran un flux posterior amb evidència documental, control reforçat o un domini específic. No s'han d'acceptar com a claus desconegudes al JSON de proposta.

---

## 3. Seguretat de sessió

### 3.1 Capacitat `personal_data`

Estendre `data.employee_portal_tokens`, les claims de `employee_portal` i `session-service.ts` amb una capacitat o `purpose` explícit:

| Capacitat | Permet |
|---|---|
| `attendance` | Superfícies actuals de calendari i fitxatge. |
| `personal_data` | Només lectura de dades de contacte pròpies i workflow de propostes. |

Per obtenir `personal_data`:

1. `shared_device = false`.
2. PIN configurat i validat.
3. JWT amb TTL de 15 minuts i `session_version` actual.
4. PIN revalidat immediatament abans de crear, cancel·lar o reenviar una proposta.
5. Token revocat, compromès, expirat o amb `session_version` antiga no pot llegir ni escriure dades.

No s'ha d'ampliar l'API pública existent perquè retorni `api.employee_private_profiles`. Es crea una superfície de portal reduïda, en què el servidor deriva `employee_id` i `tenant_id` de la sessió, mai de paràmetres lliures del client.

### 3.2 Accés temporal per a qui no té portal

RRHH pot crear un token amb `purpose='personal_data'`, durada de 24 a 72 hores, revocable, no compartit i amb PIN lliurat per un canal separat. En expirar o revocar-se, no afecta cap accés operatiu existent.

L'enllaç obre el portal i exigeix PIN abans de crear JWT. No és un endpoint `verify_jwt = false` que mostri dades o accepti canvis.

---

## 4. Model de dades i estats

### 4.1 Sol·licitud de canvi

Crear `data.employee_personal_data_change_requests` amb, com a mínim:

| Camp | Finalitat |
|---|---|
| `id`, `tenant_id`, `site_id`, `employee_id` | Aïllament multi-tenant/site i entitat afectada. |
| `portal_token_id`, `requester_kind` | Traçabilitat de la sessió que inicia la proposta. |
| `requested_patch` | JSONB amb whitelist estricta dels camps de §2.1. |
| `base_revision` | Versió o hash del perfil llegit per detectar conflictes. |
| `status` | Estat del workflow. |
| `reviewed_by`, `reviewed_at`, `review_comment` | Resolució HR. |
| `expires_at`, `created_at`, `updated_at` | SLA, caducitat i auditoria operativa. |

Estats admesos:

```text
draft -> pending_email_verification -> pending_review -> approved -> applied
                                     \-> rejected
draft/pending_email_verification/pending_review -> cancelled
pending_review -> superseded
```

- Una proposta sense canvi de `personal_email` passa directament a `pending_review`.
- Si canvia `personal_email`, passa primer a `pending_email_verification`.
- `approved` i l'actualització del perfil passen dins la mateixa transacció; no pot quedar una proposta aprovada sense aplicar.
- Si RRHH edita algun camp afectat abans de revisar-la, la proposta queda `superseded`; no se sobreescriu cap canvi més recent.

Índexs mínims:

```sql
(tenant_id, status, created_at DESC)
(employee_id, status)
```

Cal impedir més d'una proposta oberta incompatible pel mateix empleat i camp, ja sigui amb una restricció parcial o validació transaccional dins l'RPC.

### 4.2 Minimització de PII

`requested_patch` conté PII i només és accessible a l'empleat propietari, a la sessió del portal corresponent i als revisors autoritzats. No s'ha d'incloure mai el valor actual o proposat en:

- `data.audit_logs`;
- payloads PGMQ;
- logs d'Edge Functions;
- notificacions, correus o títols in-app.

L'audit només registra IDs, camps afectats i transicions d'estat.

---

## 5. Email personal nou

`employee_private_profiles.personal_email` no és `employees.email`, no participa en el hash del token del portal i no actualitza `auth.users`, `profiles` ni `tenant_members`. L'aprovació d'un canvi no invalida sessions ni modifica els destinataris operatius existents.

Si `requested_patch` modifica `personal_email`:

1. Es genera un secret aleatori de 256 bits, se'n desa només el hash i s'envia el link al nou email.
2. El token és d'un sol ús, expira en 24 hores, es revoca en cancel·lar o substituir la proposta i té límit de resend.
3. El link públic només valida el token i mou la proposta a `pending_review`; no revela la proposta, no crea una sessió de dades personals i no aplica cap canvi.
4. RRHH només pot aprovar quan l'email nou està verificat.
5. En aplicar-se, es notifica l'empleat al canal previ disponible i al nou email verificat, sense incloure PII addicional al missatge.

---

## 6. Autorització i APIs

### 6.1 Permís de revisor

Afegir `employees.private.approve_changes` al registre RBAC, els helpers JWT, `PermissionKey`, dependències de permisos i UI de configuració de rols.

- No és heretat automàticament de `employees.manage` ni de `employees.private.manage`.
- És adequat per a RRHH o DPO autoritzat.
- El revisor està subjecte a tenant i site; no pot veure propostes d'un altre tenant ni d'un site fora del seu abast.

### 6.2 RPCs del portal

Les RPCs dedueixen la identitat de les claims de sessió i no accepten `employee_id` o `tenant_id` arbitrari:

| RPC | Responsabilitat |
|---|---|
| `employee_portal_get_personal_data` | Retorna únicament els camps de §2.1 de l'empleat de la sessió. |
| `employee_portal_list_personal_data_changes` | Llista les propostes pròpies amb estat i timestamps. |
| `employee_portal_request_personal_data_change` | Valida PIN recent, whitelist, format, revisió base i crea la proposta. |
| `employee_portal_cancel_personal_data_change` | Cancel·la una proposta pròpia encara oberta. |
| `employee_portal_resend_personal_email_verification` | Reenvia sota límits una verificació pendent. |

### 6.3 RPC de revisió

`review_employee_personal_data_change(p_request_id, p_resolution, p_comment)`:

1. Valida `employees.private.approve_changes`, tenant/site i estat `pending_review`.
2. Torna a validar format, whitelist i `base_revision`.
3. En aprovar, actualitza `data.employee_private_profiles`, resol la proposta i escriu audit en una transacció única.
4. En rebutjar, conserva la proposta i registra el motiu no sensible.
5. En conflicte, marca `superseded` i exigeix una proposta nova.

L'RPC HR actual `api.upsert_employee_private_profile` continua sent per a gestió HR; no s'ha de convertir en una ruta de self-service.

---

## 7. Auditoria, notificacions i SLA

Afegir l'`entity_type` `employee_personal_data_change_request` abans de crear triggers o cridar `data.log_audit_event()`.

Accions:

- `EMPLOYEE_PERSONAL_DATA_CHANGE_REQUESTED`
- `EMPLOYEE_PERSONAL_DATA_EMAIL_VERIFIED`
- `EMPLOYEE_PERSONAL_DATA_CHANGE_APPROVED`
- `EMPLOYEE_PERSONAL_DATA_CHANGE_APPLIED`
- `EMPLOYEE_PERSONAL_DATA_CHANGE_REJECTED`
- `EMPLOYEE_PERSONAL_DATA_CHANGE_CANCELLED`
- `EMPLOYEE_PERSONAL_DATA_CHANGE_SUPERSEDED`

Les operacions de request/review encuen notificacions dins la mateixa transacció, amb `tenant_id` explícit i idempotency key determinista. Els correus i avisos in-app no inclouen el valor d'email, telèfon o adreça canviat.

SLA MVP:

| Moment | Acció |
|---|---|
| Creació | Notificació al revisor HR. |
| Dia 7 | Recordatori idempotent si segueix `pending_review`. |
| Dia 10 | Alerta/escalat a owner si segueix `pending_review`. |

El recordatori i l'escalat s'executen via cron + cua; mai amb un trigger de negoci.

---

## 8. UI i experiència

### Portal de l'empleat

- Pantalla mobile-first amb només camps admesos, formats i màscares adequades.
- Indica que la proposta queda pendent de revisió; mostra estat, data i motiu de rebuig no sensible.
- No mostra camps exclosos, metadades, notes HR ni dades d'altres persones més enllà del contacte d'emergència que l'empleat ha informat.
- Demana el PIN just abans del submit o resend.
- Mostra estats de càrrega, error, expiració de sessió i reintents segurs.

### Safata HR

- Llista només sol·licituds dins l'abast del permís.
- Compara camp a camp el valor actual amb el proposat, sense enviar-los a analytics ni logs.
- Permet aprovar o rebutjar amb comentari; tracta conflictes de versió de manera explícita.
- Filtra per site, estat, antiguitat i empleat, sense export PII en MVP.

Tot text React ha d'usar `t('employeePersonalData.clau', 'Fallback en català')` i les claus s'han d'afegir als fitxers de locale corresponents.

---

## 9. Fases

| Fase | Entregable |
|---|---|
| EHR-3.4a | ADR de capacitat `personal_data`, migració de token/session i tests de revocació/PIN. |
| EHR-3.4b | Taula de propostes, enum/constraints, RLS, RPCs portal, audit registry i tipus generats. |
| EHR-3.4c | Verificació de nou email, plantilla, limits de resend i proves de token. |
| EHR-3.4d | Permís revisor, inbox HR, RPC de resolució, notificacions i SLA 7/10 dies. |
| EHR-3.4e | UI mobile portal, UI HR, i18n, smoke i regressió completa. |

### Dependències

- EHR-3 ✅: `data.employee_private_profiles` i guards existents.
- Portal d'empleat ✅: token hash, PIN, JWT, `session_version`, revocació i access logs.
- QueueRunner/PGMQ ✅: notificacions, retry, dedup i DLQ.
- Registre canònic d'entity types ✅: cal afegir el nou codi abans de l'audit.
- Sistema de permisos ✅: cal ampliar-lo amb el nou permís.

---

## 10. Criteris d'acceptació i proves

### Seguretat i RLS

- [ ] Un token sense capacitat `personal_data`, compartit, expirat, revocat o compromès no pot veure ni crear canvis de PII.
- [ ] PIN absent, invàlid o no revalidat bloqueja la lectura o operació sensible segons el contracte definit.
- [ ] Les claims de sessió no permeten substituir `employee_id` ni `tenant_id` per valors del client.
- [ ] Un empleat només pot consultar les seves dades de §2.1 i les seves propostes.
- [ ] No hi ha grants directes del portal a `data.employee_private_profiles` ni SELECT de la vista privada completa.
- [ ] Un revisor sense `employees.private.approve_changes`, d'un altre tenant o fora de site no veu ni resol propostes.

### Workflow i integritat

- [ ] Una proposta només conté camps de la whitelist i respecta validació/normalització de cada camp.
- [ ] No s'aplica cap canvi abans de l'aprovació.
- [ ] L'email nou no arriba a `pending_review` sense token vàlid, no expirat, no revocat i d'un sol ús.
- [ ] Aprovar aplica una vegada; doble clic, retry o missatge duplicat no creen doble actualització ni notificació.
- [ ] Una edició HR concurrent marca la proposta `superseded` i no produeix lost update.
- [ ] Cancel·lar, rebutjar o expirar no altera el perfil privat.

### Audit, SLA i UX

- [ ] Audit i cues contenen IDs/camps/estats, mai valors PII.
- [ ] Es notifica el revisor en crear, es recorda al dia 7 i s'escala al dia 10 una sola vegada.
- [ ] Els correus de verificació i resolució no revelen dades sensibles.
- [ ] Smoke manual cobreix empleat amb portal existent i empleat amb token temporal `personal_data`.
- [ ] L'accés temporal de dades personals no concedeix calendari, fitxatges, documents ni altres mòduls.
- [ ] Tipus Supabase regenerats a `apps/tenant-portal/src/types/database.types.ts` i `supabase/functions/_shared/database.types.ts`.

---

## 11. Fora d'abast i evolució

- Evidència documental per canviar DNI/NIE, SS o data de naixement.
- Workflows de dades de salut, discapacitat o adaptacions.
- Autoaprovació, scoring, IA o decisions automàtiques.
- Sincronització amb payroll/HRIS extern, `auth.users` o email laboral.
- Exportacions de PII de la safata HR.
- Convertir l'enllaç de correu en un formulari públic.

Evolucions posteriors poden reutilitzar el ledger de propostes per a camps addicionals, però cada família ha de definir whitelist, validació, evidència, revisor i canal abans d'obrir-la al self-service.