# 06 — Fases i backlog d'epics

> **Pla:** [`README.md`](./README.md) · estat real a [`STATUS.md`](./STATUS.md) · ordre de treball a [`EXECUTION.md`](./EXECUTION.md)
> **Recordatori:** [`00-agent-instructions-and-guardrails.md`](./00-agent-instructions-and-guardrails.md) — **una fase per sessió**, sense excepcions.

## Fase 1 — HTML de cos complet

| Epic | Nom | Contingut | Depèn de |
|------|-----|-----------|----------|
| **QT-0** | Contracte de context + validació legal (disseny) | Fixar el contracte de variables ([`01`](./01-context-and-legal-content.md)) i l'especificació de `validate_commercial_template_locale` | — |
| **QT-1** | Migració DB | `full_body_template_id`, `resolve_commercial_full_body_template_id`, `validate_commercial_template_locale`, extensió de `upsert_document_template_locale` amb `p_acknowledge_legal_gaps` | QT-0 |
| **QT-2** | Motor de renderitzat | `commercial-document-context.ts`, branca HTML a `render-commercial-document/index.ts` | QT-1 |
| **QT-3** | Repositori de plantilles HTML | 5 plantilles de pressupost (arquetip) + 1 d'albarà genèric, ca/es, amb `sample_values` | QT-0 (contingut), en paral·lel amb QT-1/QT-2 |
| **QT-4** | Frontend | Categories noves a `/documents/templates`, selector de plantilla activa a Settings, i18n | QT-2, QT-3 |
| **QT-5** | Tests | SQL (resolver, validació, aïllament, fallback idèntic) + smoke E2E de render | QT-1, QT-2 |

**No es fa a la fase 1:** DOCX, implementació del contracte signat, enforçament numèric de mínims sectorials de validesa.

## Fase 2 — DOCX

| Epic | Nom | Contingut | Depèn de |
|------|-----|-----------|----------|
| **QT-6** | Seed + renderitzat DOCX | Estendre `generate-docx-seed.mjs` (helpers `linesTable`/`totalsBlock`/`acceptRejectBlock`), branca DOCX a `render-commercial-document`, validar/reutilitzar pipeline docx→pdf existent | Fase 1 tancada |
| **QT-7** | Frontend DOCX | Confirmar que la pujada/clonació de plantilles DOCX ja existent a `/documents/templates` funciona sense canvis per a `category='quote'`/`'delivery_note'` | QT-6 |

## Fase 3 — Signatura nativa (veure [`07-signing-integration.md`](./07-signing-integration.md))

| Epic | Nom | Contingut | Depèn de |
|------|-----|-----------|----------|
| **QT-8** | Autoria de camps de signatura | Afegir `<signature-field>`/tags DOCX (`client_accept`/`client_reject`/`client_delivery`) a les 6 plantilles seed de QT-3 | QT-3 |
| **QT-9** | Pipeline de firma | `render-commercial-document` crida `injectHtmlSignatureMarkers`/`injectDocxSignatureMarkers`; nou flux d'acceptació/refús/lliurament via `sign-document-router action=sign_native` (presencial i remot), substituint el JSON `signature:{method:'staff_ui'}` actual | QT-2, QT-8, **i la Fase 4 de `signing/pla_alineacio_firmes_docuseal_native.plan.md` (estampat a la posició de l'etiqueta), que a data 2026-09-17 encara té el checklist sense marcar — verificar/completar abans de donar QT-9 per fet** |
| **QT-10** | Submission Hub | Documents comercials firmats visibles al Centre de signatures existent (`signing_submissions` amb `signing_provider='native'`), alineat amb `docs/plans/signing/pla_alineacio_firmes_docuseal_native.plan.md` | QT-9 — la part de backend/Centre (Fase 1+3 d'aquell pla) ja està feta (verificat 2026-09-17), no bloqueja |

**Fase 3 és independent de la Fase 2 (DOCX)**: es pot fer QT-8/9/10 abans, després o en paral·lel a QT-6/7 segons prioritat de l'usuari.

## Fora d'abast (aquest pla sencer)

- Implementació del contracte signat post-acceptació — només disseny a [`05-contract-signing-forward-compat.md`](./05-contract-signing-forward-compat.md).
- Generació de factures fiscals pròpies — només nota a [`05-contract-signing-forward-compat.md`](./05-contract-signing-forward-compat.md) § 7.
- Enforçament numèric de validesa mínima sectorial (p.ex. 12 dies hàbils RD 1457/1986) — només text informatiu a la clàusula.
- Canvis de comportament de `buildCommercialDocumentHtml` per a tenants sense plantilla pròpia.
- Ampliar l'albarà a plantilles diferenciades per arquetip (només la genèrica a la fase 1).
- Crear/modificar res del pla `docs/plans/signing/pla_alineacio_firmes_docuseal_native.plan.md` — QT-10 només en depèn, no el reobre.

## Gates

### Gate QT-0 → QT-1
El contracte de variables ha d'estar acordat i documentat (no en curs de canvi) abans d'escriure cap migració que en depengui. **Tancat 2026-09-17:** [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) §1 + §2.1 congelats. QT-1 pot obrir-se.

### Gate Fase 1 → Fase 2 (QT-6)
| Ítem | Requisit |
|------|----------|
| QT-0…QT-5 | Tots ✅ a `STATUS.md`, amb proves verdes |
| Fallback provat | Un tenant real sense plantilla pròpia no ha notat cap canvi |
| Almenys un tenant real | Ha clonat i activat una plantilla HTML pròpia sense error |
| Worker DOCX→PDF localitzat | Confirmat com a reutilitzable abans d'obrir QT-6 (si no ho és, QT-6 s'ha de replantejar amb l'usuari) |

## Acceptació detallada per epic

- **QT-0**: contracte de §1 i tokens de §2.1 a [`01`](./01-context-and-legal-content.md) marcats congelats; mapeig §1.3 verificat contra `commercial_documents` / snapshots / `commercial-document-html.ts`; cap migració; `validate_commercial_template_locale` especificat a [`02`](./02-rendering-architecture.md) §2 punt 4 sense tokens extra.
- **QT-1**: numeració/resolver sense canvis per a tenants sense plantilla pròpia; aïllament multi-tenant provat; activar sense contingut legal mínim falla sense `p_acknowledge_legal_gaps`.
- **QT-2**: render HTML+PDF idèntic al fallback quan no hi ha plantilla; render amb plantilla de tenant inclou tots els camps del contracte de context sense error de sintaxi Liquid.
- **QT-3**: les 6 plantilles (5+1) tenen `sample_values` que produeixen una previsualització completa (sense camps buits ni "undefined").
- **QT-4**: un owner/manager pot triar, canviar i tornar a "cap" la plantilla activa des de Settings; totes les strings noves compleixen la Regla d'Or i18n.
- **QT-5**: suite SQL a `supabase/tests/` amb els casos de la taula de `02-rendering-architecture.md` §5, totes verdes.
- **QT-8**: les 6 plantilles seed inclouen els camps de signatura correctes (`client_accept`/`client_reject` a pressupost, `client_delivery` a albarà) i passen `validate_commercial_template_locale` sense reconeixement explícit.
- **QT-9**: acceptar/refusar un pressupost o signar un albarà crea una `document_signing_session`/`signing_submission` real amb evidència (IP, UA, imatge de signatura), no un JSON `staff_ui`; el flux remot reutilitza `/sign/:token` sense regressió del cas actual (WhatsApp/correu de CF-11).
- **QT-10**: un document comercial firmat apareix al Centre de signatures amb el mateix badge/auditoria que un document DMS firmat amb DocuSeal.
