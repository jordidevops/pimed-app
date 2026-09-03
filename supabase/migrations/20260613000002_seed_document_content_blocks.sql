/*
  Seed: Blocs de Contingut del Sistema (document_content_blocks)
  ───────────────────────────────────────────────────────────────
  Tots els blocs amb tenant_id = NULL i is_platform_default = true.
  Contingut en català (locale per defecte del projecte).
  ON CONFLICT DO UPDATE per idempotència (re-runnable).

  Categories de blocs:
  1. Documentació general d'empresa (capçaleres / peus de pàgina)
  2. RRHH (contractes, nòmines, comunicacions internes)
  3. ISO / Qualitat (control de versions, capçaleres de procediment)
  4. Legal / Protecció de dades (RGPD, avisos de confidencialitat)
*/

-- Desactivem l'enum cast implícit per poder usar text literals
-- (Postgres accepta text → enum si hi ha cast implícit, però preferim explícit)

-- =============================================================================
-- PAGE_FOOTER — TEXT (peu per a DOCX i HTML, repetit cada pàgina)
-- =============================================================================

INSERT INTO data.document_content_blocks
  (id, tenant_id, name, block_type, format, content, is_platform_default, is_active)
VALUES

-- Peu legal estàndard (DOCX / HTML)
(
  'c0000001-0000-4000-b000-000000000001',
  NULL,
  'Peu legal estàndard',
  'PAGE_FOOTER',
  'TEXT',
  '{{ tenant.name }} · Document generat el {{ globals.date }} · Tots els drets reservats.',
  true,
  true
),

-- Peu amb número de pàgina (HTML via Gotenberg — camp especial)
(
  'c0000001-0000-4000-b000-000000000002',
  NULL,
  'Peu amb número de pàgina (HTML)',
  'PAGE_FOOTER',
  'HTML',
  '<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; font-size: 9pt; color: #666; margin: 0; padding: 4px 16px; }
.footer-row { display: flex; justify-content: space-between; align-items: center; }
</style></head><body>
<div class="footer-row">
  <span>{{ tenant.name }}</span>
  <span style="font-size:8pt">Pàgina <span class="pageNumber"></span> de <span class="totalPages"></span></span>
  <span>{{ globals.date }}</span>
</div>
</body></html>',
  true,
  true
),

-- Peu d''avís de confidencialitat
(
  'c0000001-0000-4000-b000-000000000003',
  NULL,
  'Avís de confidencialitat',
  'PAGE_FOOTER',
  'TEXT',
  'DOCUMENT CONFIDENCIAL — {{ tenant.name }}. Aquest document conté informació privilegiada destinada exclusivament al destinatari. Queda prohibida la seva reproducció o divulgació sense autorització expressa.',
  true,
  true
),

-- =============================================================================
-- PAGE_HEADER — HTML (capçalera repetida cada pàgina, Gotenberg header.html)
-- =============================================================================

-- Capçalera corporativa bàsica (logo + nom)
(
  'c0000001-0000-4000-b000-000000000010',
  NULL,
  'Capçalera corporativa (logo + nom)',
  'PAGE_HEADER',
  'HTML',
  '<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; font-size: 10pt; color: #333; margin: 0; padding: 4px 16px; border-bottom: 1px solid #ddd; }
.header-row { display: flex; align-items: center; gap: 12px; }
.logo { height: 28px; max-width: 80px; object-fit: contain; }
.org-name { font-weight: 600; font-size: 11pt; }
.doc-date { margin-left: auto; font-size: 8pt; color: #888; }
</style></head><body>
<div class="header-row">
  {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="">{% endif %}
  <span class="org-name">{{ tenant.name }}</span>
  <span class="doc-date">{{ globals.date }}</span>
</div>
</body></html>',
  true,
  true
),

-- Capçalera ISO / Qualitat (codi de document, versió, data)
(
  'c0000001-0000-4000-b000-000000000011',
  NULL,
  'Capçalera ISO / Qualitat',
  'PAGE_HEADER',
  'HTML',
  '<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; font-size: 9pt; margin: 0; padding: 4px 16px; }
table { width: 100%; border-collapse: collapse; }
td { border: 1px solid #aaa; padding: 3px 8px; vertical-align: middle; }
.org { font-weight: 700; font-size: 10pt; }
.label { color: #666; font-size: 8pt; }
</style></head><body>
<table>
  <tr>
    <td rowspan="2" style="width:35%"><span class="org">{{ tenant.name }}</span></td>
    <td style="width:35%"><span class="label">Codi document:</span> {{ input.doc_code | default: "—" }}</td>
    <td style="width:15%"><span class="label">Rev.:</span> {{ input.doc_version | default: "1.0" }}</td>
    <td style="width:15%"><span class="label">Data:</span> {{ globals.date }}</td>
  </tr>
  <tr>
    <td colspan="3"><span class="label">Títol:</span> {{ input.doc_title | default: "" }}</td>
  </tr>
</table>
</body></html>',
  true,
  true
),

-- Capçalera RRHH (logo + "Document intern de Recursos Humans")
(
  'c0000001-0000-4000-b000-000000000012',
  NULL,
  'Capçalera RRHH (document intern)',
  'PAGE_HEADER',
  'HTML',
  '<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; font-size: 9pt; color: #333; margin: 0; padding: 4px 16px; border-bottom: 2px solid #1e40af; }
.header-row { display: flex; align-items: center; gap: 12px; }
.logo { height: 24px; max-width: 70px; object-fit: contain; }
.section { color: #1e40af; font-weight: 600; font-size: 9pt; }
.right { margin-left: auto; font-size: 8pt; color: #888; }
</style></head><body>
<div class="header-row">
  {% if tenant.logo_url %}<img class="logo" src="{{ tenant.logo_url }}" alt="">{% endif %}
  <span class="section">Document intern — Recursos Humans</span>
  <span class="right">{{ tenant.name }} · {{ globals.date }}</span>
</div>
</body></html>',
  true,
  true
),

-- =============================================================================
-- DOCUMENT_HEADER — HTML (capçalera dins el body, apareix un sol cop)
-- =============================================================================

-- Bloc de portada simple
(
  'c0000001-0000-4000-b000-000000000020',
  NULL,
  'Portada corporativa simple',
  'DOCUMENT_HEADER',
  'HTML',
  '<div style="text-align:center;padding:60px 0 40px;border-bottom:3px solid #1e40af;margin-bottom:40px">
  {% if tenant.logo_url %}<img src="{{ tenant.logo_url }}" style="max-height:70px;margin-bottom:20px;display:block;margin-left:auto;margin-right:auto" alt="{{ tenant.name }}">{% endif %}
  <h1 style="font-size:24pt;color:#1e3a8a;margin:0 0 8px">{{ tenant.name }}</h1>
  <p style="font-size:12pt;color:#666;margin:0">{{ globals.date }}</p>
</div>',
  true,
  true
),

-- Capçalera de document RRHH (nom treballador, càrrec)
(
  'c0000001-0000-4000-b000-000000000021',
  NULL,
  'Capçalera RRHH (treballador + càrrec)',
  'DOCUMENT_HEADER',
  'HTML',
  '<div style="display:flex;justify-content:space-between;align-items:flex-start;padding:16px 0;border-bottom:2px solid #e2e8f0;margin-bottom:24px">
  <div>
    {% if tenant.logo_url %}<img src="{{ tenant.logo_url }}" style="max-height:40px;margin-bottom:8px;display:block" alt="">{% endif %}
    <span style="font-weight:700;font-size:13pt">{{ tenant.name }}</span>
  </div>
  <div style="text-align:right;font-size:10pt;color:#555">
    <div><strong>Treballador/a:</strong> {{ Treballador.full_name | default: "—" }}</div>
    <div><strong>Càrrec:</strong> {{ Treballador.job_title | default: "—" }}</div>
    <div><strong>Data:</strong> {{ globals.date }}</div>
  </div>
</div>',
  true,
  true
),

-- =============================================================================
-- DOCUMENT_FOOTER — HTML (peu dins el body, apareix un sol cop)
-- =============================================================================

-- Bloc de signatura / peu corporatiu
(
  'c0000001-0000-4000-b000-000000000030',
  NULL,
  'Peu de signatura corporatiu',
  'DOCUMENT_FOOTER',
  'HTML',
  '<div style="margin-top:48px;border-top:1px solid #cbd5e1;padding-top:16px">
  <div style="display:flex;gap:48px">
    <div style="flex:1;text-align:center">
      <div style="border-top:1px solid #333;padding-top:6px;margin-top:40px;font-size:9pt">
        Signatura del/de la treballador/a<br>
        <strong>{{ Treballador.full_name | default: "Nom i cognoms" }}</strong>
      </div>
    </div>
    <div style="flex:1;text-align:center">
      <div style="border-top:1px solid #333;padding-top:6px;margin-top:40px;font-size:9pt">
        Per {{ tenant.name }}<br>
        <strong>{{ input.signant_empresa | default: "Representant legal" }}</strong>
      </div>
    </div>
  </div>
  <p style="font-size:8pt;color:#888;text-align:center;margin-top:16px">
    {{ tenant.name }} · {{ globals.date }}
  </p>
</div>',
  true,
  true
),

-- Avís legal extens per a contractes
(
  'c0000001-0000-4000-b000-000000000031',
  NULL,
  'Avís legal per a contractes',
  'DOCUMENT_FOOTER',
  'HTML',
  '<div style="margin-top:40px;padding:16px;background:#f8fafc;border:1px solid #e2e8f0;font-size:8pt;color:#555;line-height:1.5">
  <strong style="display:block;margin-bottom:4px">Avís legal</strong>
  Aquest document ha estat generat per {{ tenant.name }} i té caràcter vinculant per a les parts signants.
  Queda prohibida la seva reproducció, distribució o comunicació pública sense el consentiment exprés de
  {{ tenant.name }}. En cas de discrepàncies entre versions, prevaldrà el document original signat.
  Per a qualsevol consulta, adreceu-vos a {{ tenant.name }}.
</div>',
  true,
  true
),

-- =============================================================================
-- CUSTOM — HTML (blocs reutilitzables dins el body via {{ custom_block_xxx }})
-- =============================================================================

-- Clàusula RGPD (protecció de dades)
(
  'c0000001-0000-4000-b000-000000000040',
  NULL,
  'Clàusula RGPD (protecció de dades)',
  'CUSTOM',
  'HTML',
  '<div style="margin:24px 0;padding:16px;border:1px solid #fed7aa;background:#fff7ed;border-radius:6px;font-size:9pt;color:#7c2d12">
  <strong style="display:block;margin-bottom:6px">Protecció de dades personals (RGPD)</strong>
  En compliment del Reglament (UE) 2016/679 del Parlament Europeu i del Consell (RGPD) i la Llei
  Orgànica 3/2018, de Protecció de Dades Personals i Garantia dels Drets Digitals (LOPDGDD),
  s''informa que les dades personals facilitades seran tractades per <strong>{{ tenant.name }}</strong>
  amb la finalitat de gestionar la relació contractual. Les dades no seran cedides a tercers llevat
  d''obligació legal. Podeu exercir els drets d''accés, rectificació, supressió, limitació, portabilitat
  i oposició adreçant-vos a {{ tenant.name }}.
</div>',
  true,
  true
),

-- Taula de control de versions (ISO)
(
  'c0000001-0000-4000-b000-000000000041',
  NULL,
  'Taula de control de versions (ISO)',
  'CUSTOM',
  'HTML',
  '<div style="margin:24px 0">
  <strong style="display:block;margin-bottom:8px;font-size:10pt">Control de versions</strong>
  <table style="width:100%;border-collapse:collapse;font-size:9pt">
    <thead>
      <tr style="background:#f1f5f9">
        <th style="border:1px solid #cbd5e1;padding:6px 10px;text-align:left">Versió</th>
        <th style="border:1px solid #cbd5e1;padding:6px 10px;text-align:left">Data</th>
        <th style="border:1px solid #cbd5e1;padding:6px 10px;text-align:left">Autor</th>
        <th style="border:1px solid #cbd5e1;padding:6px 10px;text-align:left">Descripció del canvi</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td style="border:1px solid #cbd5e1;padding:6px 10px">{{ input.doc_version | default: "1.0" }}</td>
        <td style="border:1px solid #cbd5e1;padding:6px 10px">{{ globals.date }}</td>
        <td style="border:1px solid #cbd5e1;padding:6px 10px">{{ input.doc_author | default: "—" }}</td>
        <td style="border:1px solid #cbd5e1;padding:6px 10px">Versió inicial</td>
      </tr>
    </tbody>
  </table>
</div>',
  true,
  true
),

-- Bloc d'acceptació de condicions (RRHH)
(
  'c0000001-0000-4000-b000-000000000042',
  NULL,
  'Acceptació de condicions (RRHH)',
  'CUSTOM',
  'HTML',
  '<div style="margin:32px 0;padding:16px;border:1px solid #e2e8f0;border-radius:6px;background:#f8fafc">
  <p style="font-size:10pt;margin:0 0 12px">
    El/la treballador/a <strong>{{ Treballador.full_name | default: "—" }}</strong> declara haver rebut,
    llegit i comprès el present document, i n''accepta el contingut íntegrament.
  </p>
  <div style="display:flex;gap:48px;margin-top:24px">
    <div style="flex:1">
      <div style="border-top:1px solid #333;padding-top:4px;font-size:9pt;text-align:center">
        Signatura del/de la treballador/a
      </div>
    </div>
    <div style="flex:1">
      <div style="font-size:9pt;color:#666;text-align:center;padding-top:4px">
        Data: {{ globals.date }}
      </div>
    </div>
  </div>
</div>',
  true,
  true
)

ON CONFLICT (id) DO UPDATE SET
  name                = EXCLUDED.name,
  block_type          = EXCLUDED.block_type,
  format              = EXCLUDED.format,
  content             = EXCLUDED.content,
  is_platform_default = EXCLUDED.is_platform_default,
  is_active           = EXCLUDED.is_active,
  updated_at          = now();
