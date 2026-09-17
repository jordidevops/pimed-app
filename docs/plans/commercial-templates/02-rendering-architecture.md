# 02 — Arquitectura de renderitzat

> **Pla:** [`README.md`](./README.md) · contracte de variables [`01-context-and-legal-content.md`](./01-context-and-legal-content.md)

## 1. Estat actual (verificat al codi, 2026-09-16)

- `supabase/functions/render-commercial-document/index.ts` construeix sempre l'HTML amb `buildCommercialDocumentHtml()` (`_shared/commercial-document-html.ts`).
- `data.resolve_commercial_document_template_id(tenant_id)` (migració `20261160000010_commercial_flow_cf18_branded_pdf.sql`) resol només plantilles `category='commercial'`, `template_type='html'`, per a **capçalera/peu** (`renderTemplateBlocks()` + `document_content_blocks`).
- `commercial_documents.document_template_id` es popula automàticament en `INSERT` via `data.trg_commercial_documents_assign_render_meta()`.

**Aquest comportament no es toca.** Es manté intacte com a camí de fallback.

## 2. Canvis de base de dades (QT-1)

Nova migració, p.ex. `supabase/migrations/2026XXXXXXXXXX_commercial_templates_full_body.sql`:

1. **Columna nova** (additiva, sense tocar cap altra):
   ```sql
   ALTER TABLE data.commercial_documents
     ADD COLUMN IF NOT EXISTS full_body_template_id uuid
       REFERENCES data.document_templates(id) ON DELETE SET NULL;
   ```
   Traçabilitat: quina plantilla de cos complet es va fer servir en emetre, encara que després es desactivi o s'esborri.

2. **Resolver nou** `data.resolve_commercial_full_body_template_id(p_tenant_id uuid, p_doc_type text) RETURNS uuid`:
   - `quote_amendment` reutilitza la mateixa categoria que `quote`.
   - Prioritat: `tenants.settings.commercial.quote_template_id` / `.delivery_note_template_id` (clau nova, paral·lela a `commercial.document_template_id` ja existent) → si no, primera plantilla activa del tenant amb `category = 'quote'|'delivery_note'` i `template_type` suportat → si no, `NULL`.
   - Ha de validar que la plantilla resolta pertany al tenant o és `is_platform_default` (mateix patró que el resolver de CF-18); **mai** retornar una plantilla d'un altre tenant.

3. **Estendre el trigger** `data.trg_commercial_documents_assign_render_meta()` perquè també poblí `full_body_template_id` amb el resolver nou, sense canviar el que ja fa amb `document_template_id`/logo.

4. **Funció de validació legal** `data.validate_commercial_template_locale(p_content text, p_mime_type text, p_doc_type text) RETURNS text[]` — **especificació congelada a QT-0**, detall a [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) §2.1:
   - Cerca de **subcadenes** (no AST). Set de tokens segons `p_doc_type` (`quote`/`quote_amendment` vs `delivery_note`) i `p_mime_type` (`text/html` vs DOCX).
   - Retorna `text[]` amb els **id** de requisits absents (`lines_loop`, `totals.total`, …), en l'ordre de la taula §2.1; `{}` = vàlid.
   - `p_mime_type` desconegut o `NULL` → `{}`. `p_doc_type` invàlid → `RAISE EXCEPTION 'invalid_doc_type'`.
   - **No** llegeix Storage; `p_content` és el text que ja té l'RPC (`html_content` en HTML).
   - **No bloqueja el desar en esborrany** (`is_active=false`); **sí bloqueja l'activació** (`is_active=true`) llevat que es passi un reconeixement explícit (veure punt 5).
   - QT-1 **no afegeix** tokens ni parseig més enllà de §2.1.

5. **Estendre `api.upsert_document_template_locale`** (no trencar la signatura existent: afegir paràmetre nou amb `DEFAULT`):
   - Nou paràmetre `p_acknowledge_legal_gaps boolean DEFAULT false`.
   - Quan la plantilla associada té `category IN ('quote','delivery_note')` i `p_is_active=true`: cridar `validate_commercial_template_locale`; si retorna tokens absents i `p_acknowledge_legal_gaps` no és `true`, `RAISE EXCEPTION` amb la llista de tokens que falten (missatge accionable, no genèric).
   - Si s'activa amb reconeixement explícit: registrar-ho a `data.audit_logs` (`TEMPLATE_LEGAL_GAP_ACKNOWLEDGED`, `entity_type='document_template'`, payload amb els tokens absents).

## 3. Canvis a l'edge function (QT-2)

Nou fitxer compartit `supabase/functions/_shared/commercial-document-context.ts`:

- `buildCommercialTemplateContext(doc, lines, tenant, logoUrl): Record<string, unknown>` — construeix l'objecte de [`01-context-and-legal-content.md`](./01-context-and-legal-content.md) §1 amb el mapeig de §1.3. Consultes extra permeses: ampliar el `SELECT` de `tenants` (com `context-builder.ts`) i **una** lectura de `parent_doc_number`. Cap altra.
- Reutilitzable pel frontend de previsualització (mateix format, mateixos noms de camp).

A `render-commercial-document/index.ts`:

1. Abans de cridar `buildCommercialDocumentHtml`, cridar una nova funció `resolveCommercialFullBodyTemplate(adminData, tenantId, docType)` que fa `SELECT` sobre `commercial_documents.full_body_template_id` (ja poblat pel trigger) i la seva `document_template_locales` pel `locale` del document.
2. **Si hi ha resultat i `template_type='html'`:**
   - `context = buildCommercialTemplateContext(...)`
   - `html = await renderLiquid(locale.html_content, context)`
   - **Ometre** `buildCommercialDocumentHtml` i `renderTemplateBlocks` (el cos ja inclou capçalera/peu).
   - **Cridar `injectHtmlSignatureMarkers(html)`** (`_shared/signing-field-map.ts`, reutilitzat tal qual del motor DMS) abans de Gotenberg, per convertir qualsevol `<signature-field>` de la plantilla en la caixa visible + token `[FIRMA:role]` que després permet estampar la firma. Veure [`07-signing-integration.md`](./07-signing-integration.md).
   - Continuar amb el mateix camí de Gotenberg/`persistCommercialRenderedPdf` que ja existeix. **El PDF resultant és el «PDF base»**: si la plantilla té camps de signatura, encara no està firmat.
3. **Si no hi ha resultat:** comportament actual, sense cap canvi (fallback).
4. **Fase 2 (QT-6), si `template_type='docx'`:** descarregar bytes del bucket `document-templates`, `renderDocx(bytes, context)`, pujar el resultat com a intermedi, i crear el `document_pdf_jobs` amb `p_template_type: 'docx'` (el CHECK ja ho permet des de CF-18) en lloc de `'html'`. **Tasca d'investigació prèvia obligatòria:** localitzar el worker que ja converteix DOCX→PDF per a altres mòduls (RRHH/legal) i confirmar que és reutilitzable sense canvis per a `source_type='commercial_document'`.

## 4. Compatibilitat amb CF-18

- La categoria `commercial` (header/footer) i el seu resolver (`resolve_commercial_document_template_id`) **no es toquen**. Segueixen actius per al camí de fallback (cap plantilla `quote`/`delivery_note` resolta).
- Si un tenant té alhora una plantilla `commercial` (header/footer) i una `quote` (cos complet) activa, **guanya la de cos complet** i la de `commercial` s'ignora per a aquest document (evitar capçalera duplicada). Documentar-ho a la UI (QT-4).

## 5. Proves obligatòries (QT-5, detall tècnic)

| Prova | Criteri |
|-------|---------|
| Fallback idèntic | Tenant sense plantilla `quote`/`delivery_note`: HTML/PDF resultant idèntic abans/després del canvi |
| Resolver correcte | Amb plantilla de tenant activa, es fa servir; amb dues plantilles del mateix tenant, guanya la marcada a `tenants.settings` |
| Aïllament | Una plantilla del tenant A mai resol per al tenant B, ni amb `is_platform_default=false` ni manipulant `tenant_id` |
| Validació legal | Activar una plantilla sense bucle de línies o sense `total` falla sense `p_acknowledge_legal_gaps`; amb el flag, s'activa i queda auditat |
| Immutabilitat | `full_body_template_id` es fixa en emetre i no canvia si es desactiva la plantilla després |
| Marcadors de signatura | Una plantilla amb `<signature-field role="client_accept">` produeix un PDF base amb la caixa i el token `[FIRMA:client_accept]` detectable, sense cap firma estampada encara (veure [`07-signing-integration.md`](./07-signing-integration.md), QT-9) |
