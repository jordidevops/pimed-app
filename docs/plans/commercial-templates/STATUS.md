# Plantilles comercials — Estat d'implementació

> **Última actualització:** 2026-09-18 (estampat a etiqueta + snapshot NIF/tax_base + via jurídica)
> **Propòsit:** seguir el desenvolupament dels epics QT i deixar constància honesta del que falta.
> **Pla:** [`README.md`](./README.md) · backlog [`06-phases-and-backlog.md`](./06-phases-and-backlog.md) · ordre [`EXECUTION.md`](./EXECUTION.md)

## Llegenda

| Símbol | Significat |
|--------|------------|
| ✅ | Fet i usable |
| 🔄 | En curs |
| ❌ | No començat |
| ⚠️ | Parcial |
| 📦 | Diferit (fase 2 o fora d'abast) |

---

## Resum

**QT-10 tancat.** Un pressupost/albarà firmat natiu apareix al Centre de signatures amb el badge «Firma pròpia» i el mateix panell d'integritat que un document DMS. Pla d'epics QT-0…QT-10 tancat. Follow-up 2026-09-18: sentinel «Cap», enllaç al PDF firmat, tab Document, trigger/office gate. Estampat natiu: gate Gotenberg `detectFieldForRole(client_accept)` sobre HTML de cos complet; fail-closed si el PDF té `[FIRMA:` i el rol no es resol. Identitat emissor + `tax_base` a l'emissió. El text legal **no** és assessorament jurídic (via §6 de `01`).

Decisions tancades: fallback intacte, categories `quote`/`delivery_note` noves i mútuament excloents amb `commercial`, HTML primer/DOCX fase 2, contracte signat només forward-compat (sense epic), firma real via motor natiu del DMS (Fase 3). Tokens de `validate_commercial_template_locale` congelats (§2.1). §1 reobert 2026-09-18 només per `tax_base` (QT-D12).

## Fase 1 — HTML de cos complet

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-0 | Contracte de context + validació legal | ✅ | Congelat 2026-09-17. `tax_base` a §1 des del 2026-09-18 (QT-D12). §2.1 intacte. |
| QT-1 | Migració DB | ✅ | `20261160000014`. Proves `commercial_templates_qt1_full_body_tests.sql` PASS. Revisat 2026-09-17. |
| QT-2 | Motor de renderitzat | ✅ | Context Liquid + branca HTML. DOCX de cos complet a QT-6. |
| QT-3 | Repositori de plantilles HTML | ✅ | `20261164000001`. 5 quotes + 1 albarà, ca/es. Tokens §2.1 presents (incl. `<signature-field>` de §3/§4). Clàusules pendents de revisió jurídica. |
| QT-4 | Frontend | ✅ | Catàleg + Settings. Follow-up: sense seeds DMS «Pressupost d'obra/reparació»; badge «Plantilla de pressupost/albarà». |
| QT-5 | Tests | ✅ | `commercial_templates_qt5_tests.sql` + smoke vitest. PDF Gotenberg no es crida (mateix criteri que CF-18 TAP). |

## Fase 2 — DOCX

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-6 | Seed + renderitzat DOCX | ✅ | `20261168000001`. 5 quotes + 1 albarà DOCX, ca/es. `dottedPathParser` (el parser per defecte no resol `[[document.doc_number]]`). Worker Gotenberg DOCX ja existent. |
| QT-7 | Frontend DOCX | ✅ | Pujada/clonació DOCX a `/documents/templates` |

## Fase 3 — Signatura nativa

| Epic | Nom | Estat | Notes |
|------|-----|-------|-------|
| QT-8 | Autoria de camps de signatura | ✅ | Seeds HTML+DOCX + botó d'inserció 220×70 |
| QT-9 | Pipeline de firma nativa | ✅ | `sign_native` + payload d'events; stamp/router intactes |
| QT-10 | Submission Hub | ✅ | Vista hub + Centre: badge nativa, auditoria, enllaç al document comercial |

## Changelog

| Data | Canvi |
|------|-------|
| 2026-09-16 | Creat paquet documental (README, guardrails per a agents IA, contracte de context i clàusules, arquitectura de renderitzat, repositori de plantilles, frontend, forward-compat de contracte, fases, EXECUTION, STATUS). Decisions: fallback intacte, categories noves mútuament excloents, HTML→DOCX en dues fases, contracte només disseny. |
| 2026-09-16 | Afegida Fase 3 (QT-8/9/10): integració amb el motor de firma nativa del DMS ja existent (`sign-document-router`, `signing-field-map.ts`, Submission Hub). Nou fitxer `07-signing-integration.md`. Nota forward-compat sobre facturació fiscal futura afegida a doc 05. |
| 2026-09-17 | Correcció: el pla de signatures està només **parcialment** implementat (Fase 1 backend + Fase 3 Centre ✅; Fase 4 — estampat a la posició de l'etiqueta, exactament el que QT-9 necessita — sense marcar al checklist propi). QT-10 no bloquejat; QT-9 sí té dependència real pendent de verificar/completar. |
| 2026-09-17 | **QT-0 tancat.** Contracte de variables i tokens de validació congelats (`01` §1 / §2.1; `02` punt 4). Mapeig honest: `seller_snapshot` actual no porta NIF/adreça; `tax_breakdown` sense `tax_base`; `parent_doc_number` com a única consulta extra a QT-2. Fila duplicada de QT-9 a STATUS eliminada. Sense migració. |
| 2026-09-17 | **QT-1 tancat.** Columna `full_body_template_id`, `resolve_commercial_full_body_template_id`, `validate_commercial_template_locale` (tokens QT-0), `p_acknowledge_legal_gaps` a `upsert_document_template_locale` + audit `TEMPLATE_LEGAL_GAP_ACKNOWLEDGED`. Letterhead CF-18 intacte. Isolació multi-tenant i fallback NULL verificats a SQL. |
| 2026-09-17 | **QT-2 tancat.** `buildCommercialTemplateContext` (portal + `_shared`) mapeja el contracte §1.3 sense inventar `tax_base` ni adreça d'emissor. `render-commercial-document` usa Liquid + `injectHtmlSignatureMarkers` si hi ha plantilla HTML de cos complet del tenant/plataforma; si no, `buildCommercialDocumentHtml` + letterhead CF-18 sense canvis. DOCX de cos complet no s'obre (cau al fallback). Tests unitaris 9/9 PASS. Sense tocar `sign-document-router` / `stamp-pdf-signatures`. |
| 2026-09-17 | **QT-3 tancat.** Seed `20261164000001_commercial_templates_seed_html.sql`: 5 pressupostos (generic NULL + 4 arquetips) i 1 albarà, locales ca/es (prefixos 76/77/78/79), `sample_values` niuats del contracte. Liquid preview sense `undefined`. `validate_commercial_template_locale` buit a les 12 locales. El resolver **no** auto-assigna plantilles de plataforma (QT-D1 intacte). Text legal = punt de partida, no validat jurídicament. QT-8 continua sent l'epic d'autoria de firma (DOCX + polish); l'HTML seed ja porta els tags de §3/§4 perquè un clon passi la validació. |
| 2026-09-17 | **QT-4 tancat.** Categories `quote`/`delivery_note` seleccionables a `/documents/templates` (filtres, formulari, badge «Plantilla de cos complet» vs letterhead `commercial`). Preview Liquid amb `sample_values` niuats (`lines[]`, `totals`) i HTML complet sense doble wrap. Settings → Plantilles → Comercial: selector owner/manager de plantilles pròpies, «Cap (usar format per defecte)», merge via `commercialSettingsPatch` a `tenants.settings.commercial.quote_template_id` / `.delivery_note_template_id`. i18n dos arguments. Sense `ProjectCommercialPanel` / `CommercialDocumentView` / clone RPC. Fallback QT-D1 intacte. |
| 2026-09-17 | **QT-4 follow-up catàleg.** Retirats seeds de plataforma 022/027 (HTML+DOCX «Pressupost d'obra/reparació»). Badge/opcions «Plantilla de pressupost» / «Plantilla d'albarà» (sense «cos complet» ni jerga letterhead). Nova plantilla `quote`/`delivery_note` força HTML; tokens §2.1 al formulari i al prompt IA/còpia. Toast `commercial_template_legal_gaps`. 024 (reserva) es queda. QT-5 no obert. |
| 2026-09-17 | **QT-1 revisat.** El bloqueig «revisió humana abans de merge» es tanca després de discussió owner + IA sobre resolver, aïllament multi-tenant i `p_acknowledge_legal_gaps`. Les proves SQL d'aïllament/fallback segueixen en verd. Això no valida jurídicament el text de clàusules de QT-3. |
| 2026-09-17 | **QT-5 tancat.** Suite SQL `commercial_templates_qt5_tests.sql`: fallback NULL + letterhead intacte, resolver (més antiga / settings), aïllament (settings d'un altre tenant, `chk_doc_template_owner`, `tenant_id` mogut), validació + ack auditat, `full_body_template_id` immutable en emetre. Smoke vitest: HTML de fallback idèntic i sense `[FIRMA:]`; plantilla de cos complet + `injectHtmlSignatureMarkers` deixa caixes `sig-slot` i tokens `[FIRMA:client_accept]` sense estampar. QT-1/QT-3 regressió PASS. Sense Gotenberg, sense QT-6. |
| 2026-09-17 | **Bugfix post-QT-5.** El PDF no usava la plantilla clonada: `render-commercial-document` llegia `data.document_templates` via PostgREST, però `config.toml` no exposa l’esquema `data`. Nova RPC `api.get_commercial_full_body_locale` (SECURITY DEFINER). PDFs cachejats amb `full_body_template_id` es regeneren. Imprimir HTML i vista del document usen el mateix HTML. QT-D1 intacte si no hi ha plantilla. |
| 2026-09-17 | **Dates + tabs.** Camps `*_display` (ISO intacte, QT-D11). RPC `get_commercial_display_formats`. Plantilles `quote`/`delivery_note` (plataforma i clons) interpolen `issued_at_display`/`valid_until_display`. Vista de pressupost: tabs Resum / Document. PDFs cachejats regenerats. Firma nativa no implementada. |
| 2026-09-17 | **QT-6 tancat.** Gate worker: `process-document-pdf-queue` ja fa `docxToPdf` i `persistCommercialRenderedPdf` per `commercial_document`. Seed `generate-commercial-docx-seed.mjs` (helpers `linesTable`/`totalsBlock`/`acceptRejectBlock`, IDs 74/75/748/749). Prova Docxtemplater: cal `dottedPathParser` (sense aplanar el context). RPC `get_commercial_full_body_locale` retorna `storage_path`. Render: descarrega bucket `document-templates`, `renderDocx` + `injectDocxSignatureMarkers`, Gotenberg síncron o cua `p_template_type=docx`. Fallback QT-D1 intacte. Tests SQL QT-6 + QT-3/QT-5 PASS. Fitxers DOCX: `cd scripts && node generate-commercial-docx-seed.mjs` amb `SUPABASE_SERVICE_ROLE_KEY` per pujar-los. QT-7 no obert. |
| 2026-09-17 | **QT-7 tancat.** Nova plantilla `quote`/`delivery_note` torna a permetre DOCX (QT-4 el forçava a HTML). Upsert i clonació passen `document.xml` cercable com a `p_html_content` (el RPC valida tokens §2.1 i desa `html_content` NULL). Sense reescriure clone RPC ni `p_acknowledge_legal_gaps`. Preview Docxtemplater usa `dottedPathParser` + `sample_values` niuats. Mismatch schema-vs-DOCX omesos per cos complet (el context no viu a `variables_schema`). Settings distingeix HTML/DOCX. Vitest 20/20. Fallback QT-D1 i `buildCommercialDocumentHtml` intactes. Sense QT-8. Fitxers seed: `cd scripts && node generate-docx-seed.mjs` (veure `scripts/README.md`). |
| 2026-09-17 | **QT-8 tancat.** Acceptació detallada: 12 locales HTML de plataforma passen `validate_commercial_template_locale` sense ack i tenen `<signature-field>` 220×70 (`client_accept`/`client_reject` o `client_delivery`). 12 locales DOCX tenen els rols al `signing_roles_schema`. Editor: botó «Accepto / Refuso» o «Conformitat». SQL `commercial_templates_qt8_signature_fields_tests.sql` PASS; QT-3 regressió PASS. Sense `sign-document-router`, `stamp-pdf-signatures` ni `staff_ui` (QT-9). Fallback QT-D1 intacte. |
| 2026-09-17 | **QT-9 tancat.** Acceptar/refusar pressupost i signar albarà van per `sign-document-router action=sign_native` (presencial `SignaturePad` o remot `/sign/:token`, sense canviar CF-11 WhatsApp/email). Events a `commercial_document_events` amb `signing_submission_id`/`signing_session_id`. Compleció remota: `commercial_signing_intents` + trigger `status=signed`. `injectHtmlSignatureMarkers`/`injectDocxSignatureMarkers` ja eren a `render-commercial-document`. `sign-document-router`, `stamp-pdf-signatures` i `signing-field-map.ts` intactes: `detectFieldForRole` en viu sobre el PDF. SQL `commercial_templates_qt9_native_signing_tests.sql` PASS; vitest native-sign PASS. Fallback QT-D1 intacte. Renúncia (`staff_ui`) i close-out (`staff_closeout`) no s'han canviat. Sense QT-10. |
| 2026-09-17 | **QT-10 tancat.** Acceptació: un comercial firmat natiu es resol a `api.commercial_signing_hub` i es mostra al Centre amb el mateix badge «Firma pròpia» i panell d'integritat que un DMS natiu; l'enllaç del títol va a `/quotes?view=`. Filtre proveïdor DocuSeal/Firma pròpia. El document comercial enllaça al Centre. SQL `commercial_templates_qt10_signing_hub_tests.sql` PASS (resolució + aïllament); vitest hub PASS. Router/stamp/field-map i el pla de signatures intactes. Fallback QT-D1 intacte. El llistat del tenant de prova no tenia submissions; el filtre i la cerca s'han vist al Centre. |
| 2026-09-18 | **Follow-up 2a passada.** Sentinel `none` al resolver (Settings «Cap» = QT-D1 amb clons). Hub exposa `result_*` i la vista enllaça el PDF firmat sense tocar `rendered_document_id` ni el router. Tab Document: inject 220×70, `parent_doc_number`/`tenant.name` com l'edge, sense HTML QT-D1 si la plantilla és DOCX. Trigger d'intent ja no empassa l'apply; office gate a l'apply d'ampliacions amb l'actor que va registrar. SQL `commercial_templates_review_followup_tests.sql`. |
| 2026-09-18 | **Estampat (Fase 4, sense reobrir QT-9/10).** Gate Gotenberg: `detectFieldForRole(client_accept)` sobre HTML de cos complet amb token. Fail-closed `signature_field_not_found` si el PDF té `[FIRMA:` i el rol no es resol; sense token → peu (QT-D1). `audit_trail_storage_path` segueix sense verificar (job Edge, no SQL). |
| 2026-09-18 | **Snapshot NIF/`tax_base`.** `api.issue_commercial_document` congela `seller.tax_id`/`address_line1` des de `tenant_legal_profiles` i `tax_breakdown.tax_base` = suma de `line_net` per tipus. Docs vells: NIF buit; `tax_base` es deriva de `line_subtotal` al context. UPDATE de locales HTML de plataforma. QT-D12. Perfil legal buit = pressupost sense NIF. |
| 2026-09-18 | **Via jurídica.** Procediment a `01` §6: zero canvis de clàusules ara; quan torni l'advocat, editar fonts + migració UPDATE nova. Tokens §2.1 intactes. |
