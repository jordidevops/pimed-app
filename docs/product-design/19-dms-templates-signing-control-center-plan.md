19-## Plan: DMS + Templates + Signing Control Center

Implementar un sistema únic de composició documental amb dos camins de sortida: generació sense firma (documental intern) i enviament a firma legal. El mateix orquestrador ha de funcionar tant amb plantilles com amb documents existents del DMS des de l’inici. La vigilància i gestió del cicle de firma es resol amb una vista dedicada al tenant-portal (llistat, detall, timeline, accions i alertes en temps real).

**Steps**
1. Fase 0 - Alineació funcional i límits de scope (bloquejant)
2. Definir explícitament dos casos d’ús de primer dia: A) Signar document existent del DMS (sense passar per template), B) Generar document sense firma (DOCX/PDF) des de template o DMS.
3. Fixar el contracte de l’orquestrador: el pas de signants és opcional i només apareix si l’acció escollida és signar. Si l’usuari tria generar sense firma, el flux acaba en versió documental al DMS.
4. Excloure de MVP: recordatoris automàtics multi-etapa, cancel·lació massiva i analytics avançat.
5. Fase 1 - Model de dades (bloquejant per backend/frontend)
6. Crear taules: data.tenant_signing_config, data.document_templates, data.document_template_locales, data.signing_submissions, i nova data.signing_events per cronologia detallada de canvis d’estat/webhook.
7. Afegir camps a signing_submissions per monitoratge real: status, status_reason, last_event_at, docuseal_submission_id unique, source_type (document|template_locale), source_document_version_id, completed_at, error_message.
8. Definir RLS i vistes api.document_templates, api.document_template_locales, api.signing_submissions, api.signing_events amb seguretat invoker.
9. Afegir RPCs SECURITY DEFINER: api.create_document_template, api.consume_signing_credit, api.get_docuseal_key_for_signing, api.append_signing_event (si es vol centralitzar log).
10. Regenerar tipus a apps/tenant-portal/src/types/database.types.ts i supabase/functions/_shared/database.types.ts.
11. Fase 2 - Backend signing i document generation (paral·lel amb Fase 3)
12. Edge function sign-document-router: admetre source=document_existing i source=template_locale; descarregar fitxer original de Storage; enviar one-off a DocuSeal només si action=sign.
13. Implementar també action=generate_only perquè el backend (o frontend segons tipus) pugui crear una nova versió documental sense iniciar cap submission.
14. Per DOCX/PDF existent al DMS: si action=sign, cridar DocuSeal endpoint adequat (submissions/docx o submissions/pdf) i guardar signing_submission.
15. Per template sense firma: processar variables i guardar el resultat com nova entrada document_versions, opcionalment creant document si no existeix.
16. Edge function docuseal-webhook: validar HMAC, mapar external_id a signing_submission, persistir signing_events, actualitzar signing_submissions, descarregar PDF final i adjuntar-lo al DMS com nova versió.
17. Garantir idempotència: clau per event_id de webhook + estat final per submissió; no duplicar versions ni events.
18. Fase 3 - Frontend templates i orchestrator (paral·lel amb Fase 2)
19. Crear feature apps/tenant-portal/src/features/document-templates amb model platform-default + tenant-override + clone (patró ja validat al mòdul email).
20. TemplatesPage amb dues seccions: Sistema (read-only) i Les meves plantilles; accions Usar, Editar, Clonar, Eliminar.
21. TemplateFormModal: variables, idiomes, upload per locale i validació de placeholders.
22. DocumentOrchestrator únic per 3 entrades: template locale, document existent DMS, i futura entrada per mòduls de contractes/RRHH.
23. State machine refinada: ANALYZE -> FILL_VARIABLES -> SELECT_OUTPUT_ACTION -> (SELECT_SIGNERS només si sign) -> PROCESS -> DONE.
24. SELECT_OUTPUT_ACTION ha d’incloure sempre: generate_docx, generate_pdf, sign_docuseal. Les dues primeres han de funcionar sense tags de firma.
25. Integrar a DocumentRow (DMS) acció principal “Preparar document” + acció ràpida “Enviar a signar” per fitxers elegibles.
26. Fase 4 - Signing Flow Monitoring & Management UI (bloquejant per tancar MVP)
27. Crear Signing Center al tenant-portal: llistat de submissions amb filtres (status, data, origen, signant), cerca i paginació.
28. Crear Signing Submission Detail: capçalera d’estat, timeline d’esdeveniments (data.signing_events), signants i estat individual, errors i últim webhook.
29. Afegir accions de gestió en detall: refrescar estat, obrir document/signing URL, reenviar invitació (si DocuSeal ho permet via API), marcar com revisat internament.
30. Connectar realtime/polling seguint patró useEmailLogsRealtime: invalidació de queries + toast quan una submissió passa a declined/error/completed.
31. Afegir badges d’estat al DMS (DocumentRow i/o DocumentVersionsModal) amb deep-link al Signing Center.
32. Fase 5 - Admin-portal system templates i governança (depèn de Fase 1)
33. Nova secció admin-portal per gestionar plantilles de sistema (tenant_id null) amb mateixa semàntica de clon que email templates.
34. Definir governance mínima: versions de template, activació/desactivació, i migració segura de variables.
35. Fase 6 - Qualitat, verificació i rollout
36. Tests SQL/RLS: accés creuat entre tenants, lectura de plantilles sistema, i protecció de claus BYO.
37. Tests Edge: sign-document-router per mode platform i byo, i webhook idempotent.
38. Tests frontend: recorregut complet de generate-only (sense firma) i sign-from-DMS (amb firma).
39. UAT funcional: crear template, generar document intern, enviar document existent a signar, rebre webhook i veure timeline + estat final al frontend.
40. Rollout per feature flag tenant_signing_enabled per activar progressivament.

**Relevant files**
- c:/JordiDevops/app-supabase/supabase/migrations/20260502210551_documents_core.sql — base DMS sobre la qual afegir submissions/events i relacions de versions.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/documents/components/DocumentRow.tsx — punt d’entrada del cas “signar document existent del DMS”.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/documents/components/DocumentVersionsModal.tsx — ubicació natural per enllaçar estat de firmes i versions firmades.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/documents/api/documentsService.ts — patró callEdgeFunction i serveis per versions/document URLs.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/email/api/useEmailLogsRealtime.ts — patró reutilitzable de realtime + invalidació + alertes toast.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/email/components/EmailTemplatesTab.tsx — patró sistema+tenant+clone per catàleg de plantilles.
- c:/JordiDevops/app-supabase/apps/tenant-portal/src/features/email/api/useEmailTemplateMutations.ts — patró copy-on-write de templates plataforma.
- c:/JordiDevops/app-supabase/apps/admin-portal/app/admin/actions/email-templates.ts — referència per gestió backoffice de templates de plataforma.
- c:/JordiDevops/app-supabase/supabase/functions/_shared/supabase.ts — clients tipats i accés service role per edge functions.
- c:/JordiDevops/app-supabase/supabase/config.toml — alta de webhook públic amb verify_jwt false.

**Verification**
1. Validació model/RLS: executar test de lectura/escriptura amb usuari owner, manager, member, i tenant extern per confirmar aïllament.
2. Flux generate-only: des de template crear DOCX i PDF sense signants; comprovar nova document_version i absència de signing_submission.
3. Flux sign-from-DMS: seleccionar document existent DOCX/PDF, enviar a signar, comprovar registre signing_submission i transició d’estats.
4. Webhook end-to-end: simular eventos form.completed i submission.completed; verificar signing_events, estat final i PDF firmat al DMS.
5. Frontend monitoring: revisar Signing Center (filtres, timeline, detall, errors, deep-links) i notificacions realtime/toast en canvis crítics.
6. Regressió i18n: assegurar que tots els textos visibles nous usen t(key, fallback) al tenant-portal i admin-portal.

**Decisions**
- Inclòs explícitament en MVP: signar documents existents del DMS.
- Inclòs explícitament en MVP: generar documents sense firma des de templates i des de documents existents.
- Vigilància frontend no és opcional: Signing Center + Detail + timeline + alertes forma part del lliurable inicial.
- DocuSeal continua sent one-off per submissió, sense emmagatzematge persistent de templates a DocuSeal.
- Arquitectura de templates adopta el patró plataforma + override tenant + clone per consistència amb mòdul email.

**Further Considerations**
1. Recomanat: persistir signing_events com a taula pròpia per auditoria funcional i UX de timeline, en lloc de dependre només de l’estat agregat.
2. Recomanat: prioritzar webhook-driven updates i deixar polling com a fallback quan realtime no estigui disponible.
3. Recomanat: si generate_pdf des de DOCX és requisit estricte de qualitat legal, moure la conversió a backend per evitar diferències de render del navegador.