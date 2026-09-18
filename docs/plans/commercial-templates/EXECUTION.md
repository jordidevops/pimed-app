# Plantilles comercials — Pla mestre d'execució

> **Rol:** única font de veritat de l'ordre d'implementació i del treball pendent
> **Creat:** 2026-09-16
> **Pla:** [`README.md`](./README.md) · estat per epic: [`STATUS.md`](./STATUS.md) · epics: [`06-phases-and-backlog.md`](./06-phases-and-backlog.md)
> **Fase activa:** cap (pla d'epics tancat). QT-10 tancat 2026-09-17. No reobrir epics tancats sense acord.
> **Instruccions obligatòries:** [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md)

## Disciplina

1. Llegir aquest fitxer, [`STATUS.md`](./STATUS.md) i [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md) a l'inici de **cada** conversa d'implementació.
2. Treballar **només** la fase activa, o un ítem de backlog acordat explícitament amb l'usuari. **Mai més d'un epic per sessió** (veure guardrail 1).
3. En tancar un epic: marcar-lo a `STATUS.md`, afegir línia al changelog, avançar la fase activa aquí. **No** continuar amb l'epic següent a la mateixa sessió.
4. Cap epic es dona per fet sense la comprovació corresponent de [`06-phases-and-backlog.md`](./06-phases-and-backlog.md) § Acceptació detallada.
5. Si una decisió de [`README.md`](./README.md) § «Decisions tancades» s'ha de reobrir, es documenta abans de tocar codi.
6. Cap migració destructiva (`DROP`/`ALTER` que elimini dades o columnes existents). Només additiu.
7. Regenerar `database.types.ts` (i copiar-lo a `supabase/functions/_shared/`) després de qualsevol migració d'aquest pla.

## Ordre real

| Ordre | Epic | Estat | Nota |
|------:|------|-------|------|
| 1 | **QT-0** Contracte de context + validació legal | ✅ | Tancat 2026-09-17. Contracte i tokens congelats |
| 2 | **QT-1** Migració DB | ✅ | Tancat 2026-09-17. Revisat 2026-09-17 |
| 3 | **QT-2** Motor de renderitzat | ✅ | Tancat 2026-09-17. HTML de cos complet; DOCX queda a QT-6 |
| 3b | **QT-3** Repositori de plantilles HTML | ✅ | Tancat 2026-09-17. Seed HTML; clàusules pendents de revisió jurídica |
| 4 | **QT-4** Frontend | ✅ | Tancat 2026-09-17. Catàleg + Settings; clone RPC intacte |
| 5 | **QT-5** Tests | ✅ | Tancat 2026-09-17. SQL §5 + smoke HTML |
| — | *Gate Fase 1 → Fase 2* | ✅ | Worker DOCX→PDF reutilitzable (`process-document-pdf-queue`) |
| 6 | **QT-6** Seed + renderitzat DOCX | ✅ | Tancat 2026-09-17. Seed + render; sense frontend |
| 7 | **QT-7** Frontend DOCX | ✅ | Tancat 2026-09-17. Pujada/clonació + preview |
| 8 | **QT-8** Autoria de camps de signatura | ✅ | Tancat 2026-09-17. Seeds + editor 220×70 |
| 9 | **QT-9** Pipeline de firma nativa | ✅ | Tancat 2026-09-17. `sign_native` + events amb submission/session; stamp/router intactes |
| 10 | **QT-10** Submission Hub | ✅ | Tancat 2026-09-17. Vista hub + Centre (badge/auditoria nativa, enllaç al pressupost) |

## Registre de treball

| Data | Epic | Què s'ha fet | Següent |
|------|------|--------------|---------|
| 2026-09-17 | QT-0 | Congelat el contracte de variables i la llista executable de tokens de `validate_commercial_template_locale` (`01` §1 / §2.1, `02` punt 4). Mapeig verificat contra snapshots reals (`seller_snapshot` sense NIF/adreça; `tax_breakdown` només `tax_rate`/`tax_amount`; `parent_doc_number` com a única consulta extra a QT-2). Sense migració ni canvis a `sign-document-router` / `stamp-pdf-signatures`. | QT-1 en una sessió nova |
| 2026-09-17 | QT-1 | Migració `20261160000014_commercial_templates_qt1_full_body.sql`: `full_body_template_id`, resolver, validació de tokens, `p_acknowledge_legal_gaps` + audit. Tests SQL PASS. Tipus regenerats. Sense tocar el motor de render. | QT-2 en una sessió nova |
| 2026-09-17 | QT-2 | Context canònic (`commercial-document-context.ts` portal + Deno) i branca HTML a `render-commercial-document`: Liquid + marcadors `[FIRMA:role]` si hi ha plantilla HTML de cos complet; fallback QT-D1 idèntic si no. Aïllament: plantilla d'un altre tenant → fallback. DOCX de cos complet no implementat. Tests `commercialDocumentContext.test.ts` + `buildCommercialDocumentHtml.test.ts` PASS. | QT-3 en una sessió nova |
| 2026-09-17 | QT-3 | Seed HTML de plataforma `20261164000001`: 5 quotes + 1 albarà, ca/es, `sample_values`. Constructors a `platformCommercialHtml.ts`. Tests Liquid + SQL PASS. Sense esquema nou (no cal regenerar tipus). Fallback QT-D1 intacte: el resolver no auto-agafa plantilles `tenant_id=NULL`. El text de clàusules no està validat jurídicament. | QT-4 en una sessió nova |
| 2026-09-17 | QT-4 | Categories `quote`/`delivery_note` + badge cos complet a `/documents/templates`; preview nested; Settings Comercial escriu `quote_template_id`/`delivery_note_template_id` amb merge JSONB i opció «Cap». Tests unitaris (categories, preview, patch). i18n Regla d'Or. Sense tocar render, clone RPC ni `ProjectCommercialPanel`. | QT-5 en una sessió nova |
| 2026-09-17 | QT-4 follow-up | Retirats 022/027 de plataforma. Copy «Plantilla de pressupost/albarà»; HTML forçat; prompt IA amb contracte §1/§2.1; error de tokens accionable. 024 es queda. | QT-5 en una sessió nova |
| 2026-09-17 | QT-1 review | Tancat el bloqueig de revisió abans de merge (discussió owner + IA; aïllament SQL en verd). El text legal de QT-3 continua pendent de revisió jurídica. | QT-5 en una sessió nova |
| 2026-09-17 | QT-5 | Suite SQL §5 (`commercial_templates_qt5_tests.sql`) + smoke vitest de fallback HTML i marcadors `[FIRMA:role]` sense estampar. QT-1/QT-3 regressió PASS. Sense Gotenberg. `isFullBodyTemplateOwnedByTenant` al context (portal + Deno). | Gate Fase 1 → QT-6 en una sessió nova |
| 2026-09-17 | Bugfix post-QT-5 | RPC `get_commercial_full_body_locale`: el PDF ja no ignora la plantilla clonada. Vista/impressió HTML alineades. PDFs cachejats regenerats. | Gate Fase 1 → QT-6 en una sessió nova |
| 2026-09-17 | Dates + tabs | `issued_at_display` / `valid_until_display` / `created_at_display`; plantilles i clons usen `*_display`. Vista Resum/Document. Firma nativa no oberta. | Gate Fase 1 → QT-6 en una sessió nova |
| 2026-09-17 | QT-6 | Seed DOCX 5+1 ca/es (`20261168000001`); `dottedPathParser` a `docx-renderer`; branca DOCX a `render-commercial-document` (download + `renderDocx` + cues `template_type=docx`). Worker existent confirmat. SQL QT-6/QT-3/QT-5 PASS. Sense QT-7. | QT-7 en una sessió nova |
| 2026-09-17 | QT-7 | Pujada/clonació DOCX `quote`/`delivery_note`: XML cercable a `p_html_content` (validació §2.1, no es desa); radio DOCX reactivat; `dottedPathParser` al preview; mismatch de schema omesos per cos complet. Vitest 20/20. Sense QT-8. Clone RPC intacte. Fallback QT-D1 intacte. | QT-8 en una sessió nova |
| 2026-09-17 | QT-8 | Camps de signatura §3/§4 a les 6 plantilles (HTML ja hi eren; DOCX rols + tags). Editor HTML: botó Accepto/Refuso o Conformitat (220×70). SQL `commercial_templates_qt8_signature_fields_tests.sql` + vitest PASS. Sense `sign-document-router` / `staff_ui` (QT-9). Fallback QT-D1 intacte. | QT-9 en una sessió nova |
| 2026-09-17 | QT-9 | Acceptar/refusar/lliurament via `sign-document-router action=sign_native` (presencial SignaturePad + remot `/sign/:token`). Events amb `signing_submission_id`/`signing_session_id`. Inject ja era a render. Stamp/router/field-map intactes: `detectFieldForRole` en viu. SQL QT-9 PASS. Sense QT-10. Fallback QT-D1 intacte. | QT-10 en una sessió nova |
| 2026-09-17 | QT-10 | Documents comercials firmats al Centre: vista `api.commercial_signing_hub`, filtre proveïdor, enllaç `/quotes?view=`, badge nativa + panell d'integritat existent. SQL + vitest PASS. Sense tocar router/stamp/field-map ni el pla de signatures. Fallback QT-D1 intacte. | Pla d'epics tancat |
| 2026-09-18 | Follow-up | Sentinel `none`, enllaç `result_*` al PDF firmat, tab Document alineat (DOCX/inject/parent/tenant), trigger sense WARNING + office gate a l'apply. `20261178000001`. Router/stamp/field-map intactes. | Pla d'epics tancat |
