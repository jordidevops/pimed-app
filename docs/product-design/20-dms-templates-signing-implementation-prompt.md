# Prompt d'Implementacio per Fases: DMS + Templates + Signing Control Center

## Context
Tens el pla funcional complet a docs/product-design/19-dms-templates-signing-control-center-plan.md.

La teva missio es implementar aquest projecte en fases, amb canvis reals al codi, mantenint compatibilitat amb l'arquitectura actual del repo (Supabase multi-tenant + tenant-portal + admin-portal), i sense regressions.

## Rol i Objectiu
Actua com a enginyer senior full-stack en aquest monorepo.
Objectiu: lliurar el sistema de composicio documental amb:
1. Signatura de documents existents del DMS des del primer dia.
2. Generacio de documents sense signatura (DOCX/PDF) des de templates o des de documents existents.
3. Monitoratge i gestio del flux de signatures al frontend (tenant-portal).

## Guardrails Obligatoris del Repo
1. Frontend i18n obligatori:
   - Tot text visible al tenant-portal ha d'usar t('namespace.key', 'Fallback en catala').
   - No deixar text pla en JSX.
2. Tipus Supabase obligatoris:
   - Si toques migracions SQL que afectin data.*, api.* o RPC exposades, regenera tipus:
     - apps/tenant-portal/src/types/database.types.ts
     - supabase/functions/_shared/database.types.ts
3. Protocol d'auditoria obligatori:
   - Canvis de cicle de vida (create/delete/status change/sign flow) han de registrar-se a data.audit_logs.
4. Seguretat:
   - Clau DocuSeal mai exposada en vistes api.* ni al client.
   - Acces a clau nomes via RPC SECURITY DEFINER o entorn server-side.
5. Patrons DocuSeal:
   - Flux one-off amb POST /submissions/docx o /submissions/pdf.
   - No crear repositori persistent de templates a DocuSeal.

## Regles d'Execucio
1. Implementa fase per fase, en ordre.
2. Al final de cada fase:
   - Executa verificacions tecniques minimes.
   - Mostra resum de fitxers modificats i decisions.
   - Si queda algun risc, documenta'l.
3. No saltis fases bloquejants.
4. Si un requisit entra en conflicte amb codi existent, prioritza seguretat + i18n + tipus.

---

## Fase 1 (Bloquejant): Data Model + Seguretat + Tipus

### Objectiu
Crear el model de dades complet per templates i signing flow, amb RLS i vistes api.*.

### Treball requerit
1. Nova migracio SQL amb:
   - data.tenant_signing_config
   - data.document_templates
   - data.document_template_locales
   - data.signing_submissions
   - data.signing_events
2. Afegir constraints/indexos i enums/checks d'estat.
3. Definir RLS segons patrons del projecte (tenant isolation amb jwt_user_tenants()).
4. Crear vistes api.document_templates, api.document_template_locales, api.signing_submissions, api.signing_events.
5. Crear RPCs SECURITY DEFINER necessaries:
   - create_document_template
   - consume_signing_credit
   - get_docuseal_key_for_signing
   - append_signing_event (opcional si centralitzes event log)
6. Afegir triggers/logica d'auditoria minima per lifecycle principal.
7. Regenerar database.types.ts als dos paths obligatoris.

### Criteris d'acceptacio
1. Les noves taules existeixen amb claus i indexes esperats.
2. Un tenant no pot llegir ni escriure dades d'un altre tenant.
3. Tipus regenerats i compilacio TypeScript sense errors nous rellevants.

---

## Fase 2 (Bloquejant): Edge Functions de Signing

### Objectiu
Implementar el backend de signatura i webhook de sincronitzacio amb DMS.

### Treball requerit
1. Crear/actualitzar edge function sign-document-router:
   - Admet source=document_existing i source=template_locale.
   - Admet action=sign i action=generate_only.
   - Si action=sign:
     - Obtenir fitxer original de Storage.
     - Enviar one-off a DocuSeal (docx o pdf).
     - Crear signing_submission.
     - En mode platform, consumir credits de forma atomica.
2. Crear/actualitzar edge function docuseal-webhook:
   - Endpoint public amb validacio HMAC.
   - Mapar external_id a signing_submission.
   - Persistir signing_events i transicions d'estat.
   - Descarregar PDF final i crear nova document_version al DMS.
   - Idempotencia estricta (event dedup + evitar versions duplicades).
3. Actualitzar supabase/config.toml per webhook (verify_jwt=false on pertoqui).
4. Aplicar audit fire-and-forget a accions de codi on no hi hagi trigger.

### Criteris d'acceptacio
1. Fluix sign-from-DMS funcional end-to-end.
2. Webhook idempotent sense duplicats de versions/events.
3. Cap secret exposat al client.

---

## Fase 3 (Bloquejant): Frontend Templates + Orchestrator

### Objectiu
Lliurar la UX de composicio documental per templates i documents existents.

### Treball requerit
1. Crear feature tenant-portal de templates:
   - API service + hooks react-query.
   - TemplatesPage (sistema read-only + tenant own).
   - TemplateFormModal multi-idioma i variables.
2. Implementar model plataforma + tenant override + clone (copy-on-write).
3. Crear DocumentOrchestrator amb estat:
   - ANALYZE -> FILL_VARIABLES -> SELECT_OUTPUT_ACTION -> SELECT_SIGNERS (condicional) -> PROCESS -> DONE
4. Output actions obligatories:
   - generate_docx
   - generate_pdf
   - sign_docuseal
5. Integrar al DMS:
   - Accio principal Preparar document
   - Accio rapida Enviar a signar a DocumentRow
6. Garantir i18n a tots els textos nous amb t(key, fallback).

### Criteris d'acceptacio
1. Es pot generar document sense signar des de template.
2. Es pot signar document existent del DMS.
3. La UI no te literals de text pla nous.

---

## Fase 4 (Bloquejant): Signing Monitoring & Management UI

### Objectiu
Donar observabilitat operativa del flux de signatures al tenant-portal.

### Treball requerit
1. Crear Signing Center (llistat):
   - filtres per status/origen/signant/data
   - cerca
   - paginacio
2. Crear Signing Submission Detail:
   - estat actual + motiu
   - timeline de signing_events
   - signants i estat individual
   - errors i ultim webhook
3. Accions operatives en detall:
   - refrescar estat
   - obrir document/signing URL
   - reenviament (si API DocuSeal ho suporta)
4. Realtime/polling:
   - reutilitzar patro tipus useEmailLogsRealtime per invalidacio de queries i toasts d'estats critics.
5. Integrar badges d'estat de firma al DMS (DocumentRow i/o DocumentVersionsModal) amb deep-link al Signing Center.

### Criteris d'acceptacio
1. Operacio de seguiment de signatures sense entrar a consola externa.
2. Transicions d'estat visibles en timeline.
3. Alertes de failed/declined/completed a UI.

---

## Fase 5 (No Bloquejant): Admin-portal per Templates de Sistema

### Objectiu
Permetre gestionar templates de sistema per a tots els tenants.

### Treball requerit
1. Nova seccio admin-portal per CRUD de templates de sistema (tenant_id null).
2. Flux de clon cap a tenant mantenint semantica consistent amb email templates.
3. Governanca minima:
   - activacio/desactivacio
   - control de versions
   - canvis de variables amb backward compatibility basica.

### Criteris d'acceptacio
1. Admin pot publicar templates globals.
2. Tenant pot clonar i personalitzar sense afectar l'original.

---

## Fase 6: Qualitat, Verificacio i Rollout

### Objectiu
Assegurar estabilitat tecnica i desplegament progressiu.

### Treball requerit
1. Tests SQL/RLS i de seguretat multi-tenant.
2. Tests Edge de sign-document-router i webhook.
3. Tests frontend dels dos camins principals:
   - generate-only
   - sign-from-DMS
4. Regressio i18n i tipus.
5. Rollout amb feature flag tenant_signing_enabled.

### Criteris d'acceptacio
1. No hi ha regressions crtiques en DMS existent.
2. Fluxos principals validats en UAT.
3. Deploy activable per tenants pilot.

---

## Format de resposta esperat de la IA implementadora
Per cada fase completada, retorna:
1. Resum de canvis implementats.
2. Llistat de fitxers tocats.
3. Migracions i impacte DB.
4. Verificacions executades i resultat.
5. Riscos pendents i seguent pas recomanat.

## Comencar ara
Comenca per Fase 1 i no avancis a la Fase 2 fins haver completat i verificat tota la Fase 1.