-- =============================================================================
-- Seed de plantilles documentals de plataforma (producció)
-- HTML/DOCX 001-007, 015-028 + default_block_mapping
-- Demo Acme 008-014 → supabase/seed.sql (requereix tenant de prova)
-- =============================================================================

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
('70000000-0000-0000-0000-000000000001', NULL,                                   'Contracte de treball indefinit',       'Contracte estàndard per a noves incorporacions.',             'hr',         'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000002', NULL,                                   'Sol·licitud de vacances',              'Formulari de sol·licitud de vacances anuals.',                'hr',         'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000003', NULL,                                   'Sol·licitud canvi de jornada',         'Petició formal de canvi de distribució horària.',             'hr',         'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000004', NULL,                                   'Acta de lliurament d''EPI',            'Acta de recepció d''equips de protecció individual.',         'safety',     'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000005', NULL,                                   'Declaració de confidencialitat',       'Acord de confidencialitat i no-divulgació.',                  'legal',      'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000006', NULL,                                   'Sol·licitud d''avançament salarial',   'Petició d''avançament sobre nòmina futura.',                 'hr',         'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000007', NULL,                                   'Butlletí d''acollida',                 'Document informatiu per a nous treballadors (generar i lliurar).','hr',   'html', true,  true, NULL),
('70000000-0000-0000-0000-000000000015', NULL,                                   'Test de firmes',                       'Document de referència per a proves de signatura (DocuSeal i firma pròpia).', 'signing', 'html', true, true, NULL)
ON CONFLICT DO NOTHING;

-- ─── Plantilles HTML: variables_schema i sintaxi de variables ───────────────
-- Dos enfocaments conviuen:
--   A) Schema-based: clau = camp DB (full_name, document_id, job_title) + "role" → l'usuari veu el camp pre-omplert i pot editar-lo.
--   B) Path-based:  {{Rol.camp}} directament a l'HTML → resolt automàticament des del role assignment, l'usuari no veu cap camp de formulari.
-- Plantilles 1-3, 8-10, 12 → enfocament A.  Plantilles 4, 5, 6, 13 → enfocament B.


INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '71000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001','ca','text/html',NULL,
  '<h1>Contracte de Treball Indefinit</h1><p>Entre l''empresa <strong>Acme Corp S.A.</strong> i el/la treballador/a <strong>{{full_name}}</strong>, DNI <strong>{{document_id}}</strong>.</p><p>Data d''incorporació: <strong>{{data_inici}}</strong>. Càrrec: <strong>{{job_title}}</strong>.</p><p>Salari brut anual: <strong>{{salari_anual}} EUR</strong>. Jornada: <strong>{{jornada_hores}} h/setmana</strong>.</p><p>Les parts signen de conformitat amb la legislació laboral vigent.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"document_id":{"type":"string","label":"DNI/NIE","required":true,"role":"worker","order":1},"job_title":{"type":"string","label":"Càrrec","required":true,"role":"worker","order":2},"data_inici":{"type":"date","label":"Data d''incorporació","required":true,"order":3},"salari_anual":{"type":"number","label":"Salari brut anual (EUR)","required":true,"order":4},"jornada_hores":{"type":"number","label":"Hores setmanals","required":true,"order":5}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Maria Garcia Lopez","document_id":"12345678A","job_title":"Tecnic/a","data_inici":"2025-09-01","salari_anual":"28000","jornada_hores":"40"}',
  true
),
(
  '71000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000002','ca','text/html',NULL,
  '<h1>Sol·licitud de Vacances</h1><p>El/la treballador/a <strong>{{full_name}}</strong> sol·licita vacances del <strong>{{data_inici}}</strong> al <strong>{{data_fi}}</strong> (<strong>{{dies}}</strong> dies laborables).</p><p>Data sol·licitud: <strong>{{data_sol}}</strong>.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data_inici":{"type":"date","label":"Data inici vacances","required":true,"order":1},"data_fi":{"type":"date","label":"Data fi vacances","required":true,"order":2},"dies":{"type":"number","label":"Dies laborables","required":true,"order":3},"data_sol":{"type":"date","label":"Data sol·licitud","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"direct_manager":{"entity_type":"employee","label":"Cap immediat","order":1,"for_signing":true}}',
  '{"full_name":"Marc Vila Bosch","data_inici":"2025-08-01","data_fi":"2025-08-15","dies":"11","data_sol":"2025-06-15"}',
  true
),
(
  '71000000-0000-0000-0000-000000000003','70000000-0000-0000-0000-000000000003','ca','text/html',NULL,
  '<h1>Sol·licitud de Canvi de Jornada</h1><p>El/la treballador/a <strong>{{full_name}}</strong> sol·licita modificar la seva jornada a <strong>{{nova_jornada}}</strong> hores setmanals, amb efectes des del <strong>{{data_efecte}}</strong>.</p><p>Motiu: {{motiu}}.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nova_jornada":{"type":"number","label":"Nova jornada (h/setmana)","required":true,"order":1},"motiu":{"type":"string","label":"Motiu","required":true,"order":2},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Laia Torres Serra","nova_jornada":"32","motiu":"Conciliacio familiar","data_efecte":"2025-10-01"}',
  true
),
(
  '71000000-0000-0000-0000-000000000004','70000000-0000-0000-0000-000000000004','ca','text/html',NULL,
  '{{ document_header }}<h1>Acta de Lliurament d''EPI</h1><p>En data <strong>{{data_lliurament}}</strong> s''han lliurat al/a la treballador/a <strong>{{worker.full_name}}</strong> els EPI: <strong>{{llista_epi}}</strong>.</p><p>El/la treballador/a es compromet a usar-los correctament i comunicar qualsevol deficiència.</p>{{ document_footer }}',
  '{"data_lliurament":{"type":"date","label":"Data de lliurament","required":true,"order":0},"llista_epi":{"type":"string","label":"Llista EPI lliurats","required":true,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"safety_supervisor":{"entity_type":"employee","label":"Supervisor/a PRL","order":1,"for_signing":true,"auto_assign_current_user":true}}',
  '{"data_lliurament":"2025-07-01","llista_epi":"Casc, guants, ulleres, botes de seguretat"}',
  true
),
(
  '71000000-0000-0000-0000-000000000005','70000000-0000-0000-0000-000000000005','ca','text/html',NULL,
  '<h1>Declaració de Confidencialitat i No-Divulgació</h1><p>Jo, <strong>{{worker.full_name}}</strong>, em comprometo a mantenir en estricta confidencialitat tota la informació reservada a la qual accedeixi en les meves funcions. Aquesta obligació es manté indefinidament un cop extingida la relació laboral.</p><p>Signat a Barcelona, a <strong>{{data}}</strong>.</p>',
  '{"data":{"type":"date","label":"Data de signatura","required":true,"order":0}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true}}',
  '{"data":"2025-07-15"}',
  true
),
(
  '71000000-0000-0000-0000-000000000006','70000000-0000-0000-0000-000000000006','ca','text/html',NULL,
  '<h1>Sol·licitud d''Avançament de Nomina</h1><p>El/la treballador/a <strong>{{worker.full_name}}</strong> sol·licita un avançament de <strong>{{import_sol}} EUR</strong>. Motiu: {{motiu}}.</p><p>L''import es descomptarà de la propera nòmina.</p>',
  '{"import_sol":{"type":"number","label":"Import sol·licitat (EUR)","required":true,"order":0},"motiu":{"type":"string","label":"Motiu","required":false,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_director":{"entity_type":"employee","label":"Director/a RRHH","order":1,"for_signing":true}}',
  '{"import_sol":"500","motiu":"Despeses mediques imprevistes"}',
  true
),
(
  '71000000-0000-0000-0000-000000000007','70000000-0000-0000-0000-000000000007','ca','text/html',NULL,
  '<h1>Benvingut/da a l''Empresa</h1><p>Estimat/da <strong>{{nom_treballador}}</strong>, et donem la benvinguda a Acme Corp amb motiu de la teva incorporació el <strong>{{data_incorporacio}}</strong>.</p><p>El/la teu/teva responsable d''acollida serà <strong>{{responsable_acollida}}</strong>. Qualsevol dubte, contacta amb RRHH.</p>',
  '{"nom_treballador":{"type":"string","label":"Nom del treballador/a","required":true,"order":0},"data_incorporacio":{"type":"date","label":"Data d''incorporació","required":true,"order":1},"responsable_acollida":{"type":"string","label":"Responsable d''acollida","required":true,"order":2}}',
  '{}',
  '{"nom_treballador":"Montserrat Puig Ferrer","data_incorporacio":"2025-09-01","responsable_acollida":"Alice (Acme)"}',
  true
),
(
  '71000000-0000-0000-0000-000000000015','70000000-0000-0000-0000-000000000015','ca','text/html',NULL,
  '<h1>Test de Firmes</h1><p>Document de prova generat el <strong>{{data_prova}}</strong>.</p><p>Treballador/a: <strong>{{worker.full_name}}</strong></p><p>Notes: {{notes}}</p><hr/><p>Signatura treballador/a:</p><signature-field name="FirmaTreballador" role="worker" required="true" style="width:180px;height:60px;display:inline-block;"></signature-field><p>Data signatura treballador/a:</p><date-field name="DataTreballador" role="worker" required="true" style="width:120px;height:24px;display:inline-block;"></date-field><p>Signatura responsable:</p><signature-field name="FirmaResponsable" role="manager" required="true" style="width:180px;height:60px;display:inline-block;"></signature-field>',
  '{"worker.full_name":{"type":"string","label":"Nom treballador/a","required":true,"role":"worker","order":0},"data_prova":{"type":"date","label":"Data de la prova","required":true,"order":1},"notes":{"type":"string","label":"Notes de prova","required":false,"order":2}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable","order":1,"for_signing":true}}',
  '{"worker.full_name":"Marc Vila Bosch","data_prova":"2026-06-15","notes":"Plantilla de prova per a DocuSeal i firma propia"}',
  true
)
ON CONFLICT DO NOTHING;


-- ─── B5. Plantilles de documents DOCX ─────────────────────────────────────
-- Prefix 72: document_templates  (001-007 plataforma, 008-014 Acme Corp, 015 Test de firmes)
-- Prefix 73: document_template_locales (001-015, locale='ca', mime=docx)
-- Generat amb: cd scripts && SUPABASE_SERVICE_ROLE_KEY=<key> node generate-docx-seed.mjs



INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
('72000000-0000-0000-0000-000000000001', NULL, 'Contracte de treball indefinit', 'Contracte estàndard per a noves incorporacions.', 'hr', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000002', NULL, 'Sol·licitud de vacances', 'Formulari de sol·licitud de vacances anuals.', 'hr', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000003', NULL, 'Sol·licitud canvi de jornada', 'Petició formal de canvi de distribució horària.', 'hr', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000004', NULL, 'Acta de lliurament d''EPI', 'Acta de recepció d''equips de protecció individual.', 'safety', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000005', NULL, 'Declaració de confidencialitat', 'Acord de confidencialitat i no-divulgació.', 'legal', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000006', NULL, 'Sol·licitud d''avançament salarial', 'Petició d''avançament sobre nòmina futura.', 'hr', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000007', NULL, 'Butlletí d''acollida', 'Document informatiu per a nous treballadors (generar i lliurar).', 'hr', 'docx', true, true, NULL),
('72000000-0000-0000-0000-000000000015', NULL, 'Test de firmes', 'Document de referència per a proves de signatura (DocuSeal i firma pròpia).', 'signing', 'docx', true, true, NULL)
ON CONFLICT DO NOTHING;



INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/01-contracte-treball-indefinit-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"document_id":{"type":"string","label":"DNI/NIE","required":true,"role":"worker","order":1},"job_title":{"type":"string","label":"Càrrec","required":true,"role":"worker","order":2},"data_inici":{"type":"date","label":"Data d''incorporació","required":true,"order":3},"salari_anual":{"type":"number","label":"Salari brut anual (EUR)","required":true,"order":4},"jornada_hores":{"type":"number","label":"Hores setmanals","required":true,"order":5}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Maria Garcia Lopez","document_id":"12345678A","job_title":"Tècnic/a","data_inici":"2025-09-01","salari_anual":"28000","jornada_hores":"40"}',
  true
),
(
  '73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000002', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/02-sollicitud-vacances-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data_inici":{"type":"date","label":"Data inici vacances","required":true,"order":1},"data_fi":{"type":"date","label":"Data fi vacances","required":true,"order":2},"dies":{"type":"number","label":"Dies laborables","required":true,"order":3},"data_sol":{"type":"date","label":"Data de la sol·licitud","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"direct_manager":{"entity_type":"employee","label":"Cap immediat","order":1,"for_signing":true}}',
  '{"full_name":"Marc Vila Bosch","data_inici":"2025-08-01","data_fi":"2025-08-15","dies":"11","data_sol":"2025-06-15"}',
  true
),
(
  '73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000003', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/03-sollicitud-canvi-jornada-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nova_jornada":{"type":"number","label":"Nova jornada (h/setmana)","required":true,"order":1},"motiu":{"type":"string","label":"Motiu de la petició","required":true,"order":2},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Laia Torres Serra","nova_jornada":"32","motiu":"Conciliació familiar","data_efecte":"2025-10-01"}',
  true
),
(
  '73000000-0000-0000-0000-000000000004', '72000000-0000-0000-0000-000000000004', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/04-acta-lliurament-epi-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data_lliurament":{"type":"date","label":"Data de lliurament","required":true,"order":1},"llista_epi":{"type":"string","label":"EPI lliurats","required":true,"order":2}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"safety_supervisor":{"entity_type":"employee","label":"Supervisor/a PRL","order":1,"for_signing":true}}',
  '{"full_name":"Joan Puig Ferrer","data_lliurament":"2025-07-01","llista_epi":"Casc, guants, ulleres, botes de seguretat"}',
  true
),
(
  '73000000-0000-0000-0000-000000000005', '72000000-0000-0000-0000-000000000005', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/05-declaracio-confidencialitat-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data":{"type":"date","label":"Data de signatura","required":true,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true}}',
  '{"full_name":"Anna Soler Mas","data":"2025-07-15"}',
  true
),
(
  '73000000-0000-0000-0000-000000000006', '72000000-0000-0000-0000-000000000006', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/06-sollicitud-avancament-salarial-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"import_sol":{"type":"number","label":"Import sol·licitat (EUR)","required":true,"order":1},"motiu":{"type":"string","label":"Motiu","required":false,"order":2}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_director":{"entity_type":"employee","label":"Director/a RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Marc Vila Bosch","import_sol":"500","motiu":"Despeses mèdiques imprevistes"}',
  true
),
(
  '73000000-0000-0000-0000-000000000007', '72000000-0000-0000-0000-000000000007', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/07-butlleti-acollida-ca.docx', NULL,
  '{"nom_treballador":{"type":"string","label":"Nom del treballador/a","required":true,"order":0},"data_incorporacio":{"type":"date","label":"Data d''incorporació","required":true,"order":1},"responsable_acollida":{"type":"string","label":"Responsable d''acollida","required":true,"order":2}}',
  '{}',
  '{"nom_treballador":"Montserrat Puig Ferrer","data_incorporacio":"2025-09-01","responsable_acollida":"Alice (Acme)"}',
  true
),
(
  '73000000-0000-0000-0000-000000000015', '72000000-0000-0000-0000-000000000015', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/15-test-de-firmes-ca.docx', NULL,
  '{"worker.full_name":{"type":"string","label":"Nom treballador/a","required":true,"role":"worker","order":0},"data_prova":{"type":"date","label":"Data de la prova","required":true,"order":1},"notes":{"type":"string","label":"Notes de prova","required":false,"order":2}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable","order":1,"for_signing":true}}',
  '{"worker.full_name":"Marc Vila Bosch","data_prova":"2026-06-15","notes":"Plantilla de prova per a DocuSeal i firma pròpia"}',
  true
)
ON CONFLICT DO NOTHING;

-- ─── B5b. Archetype tagging — platform templates (F16) ──────────────────────
-- NULL = universal; array = sectors on té sentit per defecte.
-- HTML series (70-prefix)
UPDATE data.document_templates SET target_archetypes = ARRAY['hospitality','workshop_maker','practice','generic'] WHERE id IN ('70000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000003','70000000-0000-0000-0000-000000000006','70000000-0000-0000-0000-000000000007','70000000-0000-0000-0000-000000000015');
UPDATE data.document_templates SET target_archetypes = ARRAY['field_service','workshop_maker','hospitality'] WHERE id = '70000000-0000-0000-0000-000000000004';
-- 005 (confidencialitat) + 013 (RGPD) → NULL (universal, no cal UPDATE)
-- DOCX series (72-prefix)
UPDATE data.document_templates SET target_archetypes = ARRAY['hospitality','workshop_maker','practice','generic'] WHERE id IN ('72000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000003','72000000-0000-0000-0000-000000000006','72000000-0000-0000-0000-000000000007','72000000-0000-0000-0000-000000000015');
UPDATE data.document_templates SET target_archetypes = ARRAY['field_service','workshop_maker','hospitality'] WHERE id = '72000000-0000-0000-0000-000000000004';

-- ── Format de dates Liquid (dd/mm/aaaa) ─────────────────────────────────────
-- Millora: dates amb filtre dd/mm/aaaa a plantilles HTML existents
UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data_inici}}', '{{ data_inici | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html' AND html_content LIKE '%{{data_inici}}%';

UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data_fi}}', '{{ data_fi | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html' AND html_content LIKE '%{{data_fi}}%';

UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data_sol}}', '{{ data_sol | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html' AND html_content LIKE '%{{data_sol}}%';

UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data_efecte}}', '{{ data_efecte | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html' AND html_content LIKE '%{{data_efecte}}%';

UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data_lliurament}}', '{{ data_lliurament | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html' AND html_content LIKE '%{{data_lliurament}}%';

UPDATE data.document_template_locales
SET html_content = REPLACE(html_content, '{{data}}', '{{ data | date: "%d/%m/%Y" }}')
WHERE mime_type = 'text/html'
  AND html_content LIKE '%{{data}}%'
  AND template_id IN ('70000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000013');








-- ── Noves plantilles HTML 016-028 ────────────────────────────────────────────
INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
  ('70000000-0000-0000-0000-000000000016', NULL, 'Carta d''advertència laboral', 'Comunicació formal d''advertència o amonestació a l''empleat/da.', 'hr', 'html', true, true, NULL, ARRAY['generic','practice','hospitality','workshop_maker']),
  ('70000000-0000-0000-0000-000000000017', NULL, 'Acord de teletreball', 'Acord individual de treball a distància.', 'hr', 'html', true, true, NULL, ARRAY['generic','practice']),
  ('70000000-0000-0000-0000-000000000018', NULL, 'Consentiment informat', 'Full de consentiment informat per a actes o tractaments (clínica, consulta).', 'legal', 'html', true, true, NULL, ARRAY['practice']),
  ('70000000-0000-0000-0000-000000000019', NULL, 'Full d''admissió de pacient/client', 'Obertura d''expedient amb dades del pacient o client.', 'operations', 'html', true, true, NULL, ARRAY['practice']),
  ('70000000-0000-0000-0000-000000000020', NULL, 'Informe de visita o sessió', 'Registre intern de visita professional (sense signatura).', 'operations', 'html', true, true, NULL, ARRAY['practice']),
  ('70000000-0000-0000-0000-000000000021', NULL, 'Full d''intervenció tècnica', 'Acta d''intervenció a domicili o instal·lació del client.', 'operations', 'html', true, true, NULL, ARRAY['field_service']),
  ('70000000-0000-0000-0000-000000000022', NULL, 'Pressupost d''obra o instal·lació', 'Oferta econòmica per a client amb acceptació per signatura.', 'commercial', 'html', true, true, NULL, ARRAY['field_service','workshop_maker']),
  ('70000000-0000-0000-0000-000000000023', NULL, 'Certificat de finalització de treballs', 'Certificació de treballs completats amb signatura del client.', 'operations', 'html', true, true, NULL, ARRAY['field_service']),
  ('70000000-0000-0000-0000-000000000024', NULL, 'Contracte de reserva d''esdeveniment', 'Reserva de sala o esdeveniment privat amb signatura del client.', 'commercial', 'html', true, true, NULL, ARRAY['hospitality']),
  ('70000000-0000-0000-0000-000000000025', NULL, 'Full de comanda de càtering', 'Comanda interna de càtering (sense signatura).', 'operations', 'html', true, true, NULL, ARRAY['hospitality']),
  ('70000000-0000-0000-0000-000000000026', NULL, 'Ordre de reparació', 'Recepció d''equipament o vehicle amb signatura del client.', 'operations', 'html', true, true, NULL, ARRAY['workshop_maker']),
  ('70000000-0000-0000-0000-000000000027', NULL, 'Pressupost de reparació', 'Pressupost amb acceptació del client.', 'commercial', 'html', true, true, NULL, ARRAY['workshop_maker']),
  ('70000000-0000-0000-0000-000000000028', NULL, 'Certificat de lliurament', 'Lliurament d''equip reparat amb signatura del client.', 'operations', 'html', true, true, NULL, ARRAY['workshop_maker'])
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
-- 016 Carta advertència
('71000000-0000-0000-0000-000000000016','70000000-0000-0000-0000-000000000016','ca','text/html',NULL,
 '<h1>Carta d''Advertència</h1><p>A l''atenció de <strong>{{ worker.full_name }}</strong> (DNI {{ worker.document_id }}).</p><p>En data <strong>{{ data_avis | date: "%d/%m/%Y" }}</strong> se us comunica la següent incidència: {{ descripcio_incidencia }}.</p><p>Motiu: {{ motiu }}. Gravetat: {{ gravetat | default: "lleu" }}.</p><p>Es requereix correcció immediata. Signatura de conformitat:</p><signature-field role="worker"></signature-field><p>Responsable RRHH:</p><signature-field role="hr_manager"></signature-field>',
 '{"data_avis":{"type":"date","label":"Data de l''advertència","required":true,"order":0},"descripcio_incidencia":{"type":"string","label":"Descripció de la incidència","required":true,"order":1},"motiu":{"type":"string","label":"Motiu","required":true,"order":2},"gravetat":{"type":"string","label":"Gravetat","required":false,"order":3}}',
 '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
 '{"data_avis":"2026-03-01","descripcio_incidencia":"Retards reiterats","motiu":"Incompliment horari","gravetat":"lleu"}', true),

-- 017 Teletreball
('71000000-0000-0000-0000-000000000017','70000000-0000-0000-0000-000000000017','ca','text/html',NULL,
 '<h1>Acord de Teletreball</h1><p>Entre {{ tenant.name }} i <strong>{{ worker.full_name }}</strong>, s''acorda el teletreball des del <strong>{{ data_inici | date: "%d/%m/%Y" }}</strong>.</p><p>Dies: {{ dies_tele }} · Horari: {{ horari }} · Lloc: {{ lloc_treball }}.</p><signature-field role="worker"></signature-field><signature-field role="hr_manager"></signature-field>',
 '{"data_inici":{"type":"date","label":"Data d''inici","required":true,"order":0},"dies_tele":{"type":"string","label":"Dies de teletreball","required":true,"order":1},"horari":{"type":"string","label":"Horari","required":true,"order":2},"lloc_treball":{"type":"string","label":"Lloc de treball","required":true,"order":3}}',
 '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true},"tenant":{"entity_type":"tenant","label":"Empresa","order":2,"for_signing":false}}',
 '{"data_inici":"2026-04-01","dies_tele":"Dl-Dv","horari":"9-18h","lloc_treball":"Domicili"}', true),

-- 018 Consentiment informat (practice)
('71000000-0000-0000-0000-000000000018','70000000-0000-0000-0000-000000000018','ca','text/html',NULL,
 '{{ document_header }}<h1>Consentiment informat</h1><p>Jo, <strong>{{ client_signatory.display_name }}</strong>, he estat informat/da sobre: {{ procediment }}.</p><p>Riscos i beneficis explicats. Data: {{ data_consentiment | date: "%d/%m/%Y" }}.</p><signature-field role="client_signatory"></signature-field>{{ document_footer }}',
 '{"procediment":{"type":"string","label":"Procediment o tractament","required":true,"order":0},"data_consentiment":{"type":"date","label":"Data","required":true,"order":1}}',
 '{"client_signatory":{"entity_type":"contact","label":"Pacient/Client","order":0,"for_signing":true},"worker":{"entity_type":"employee","label":"Professional","order":1,"for_signing":false}}',
 '{"procediment":"Tractament dental rutinari","data_consentiment":"2026-03-10"}', true),

-- 019 Admissió pacient
('71000000-0000-0000-0000-000000000019','70000000-0000-0000-0000-000000000019','ca','text/html',NULL,
 '<h1>Full d''admissió</h1><p>Client: <strong>{{ client_signatory.display_name }}</strong> · Tel: {{ client_signatory.phone | default: "—" }}</p><p>Motiu consulta: {{ motiu }}. Antecedents: {{ antecedents | default: "Cap" }}.</p><p>Data: {{ data_admissio | date: "%d/%m/%Y" }}</p><signature-field role="client_signatory"></signature-field>',
 '{"motiu":{"type":"string","label":"Motiu de consulta","required":true,"order":0},"antecedents":{"type":"string","label":"Antecedents","required":false,"order":1},"data_admissio":{"type":"date","label":"Data admissió","required":true,"order":2}}',
 '{"client_signatory":{"entity_type":"contact","label":"Pacient/Client","order":0,"for_signing":true}}',
 '{"motiu":"Primera visita","antecedents":"","data_admissio":"2026-03-10"}', true),

-- 020 Informe visita (intern)
('71000000-0000-0000-0000-000000000020','70000000-0000-0000-0000-000000000020','ca','text/html',NULL,
 '<h1>Informe de visita</h1><p>Professional: {{ worker.full_name }} · Client: {{ client_signatory.display_name }}</p><p>Data: {{ data_visita | date: "%d/%m/%Y" }}</p><p>Observacions: {{ observacions }}</p><p>Pla: {{ pla_seguiment | default: "—" }}</p>',
 '{"data_visita":{"type":"date","label":"Data visita","required":true,"order":0},"observacions":{"type":"string","label":"Observacions","required":true,"order":1},"pla_seguiment":{"type":"string","label":"Pla de seguiment","required":false,"order":2}}',
 '{"worker":{"entity_type":"employee","label":"Professional","order":0,"for_signing":false},"client_signatory":{"entity_type":"contact","label":"Client","order":1,"for_signing":false}}',
 '{"data_visita":"2026-03-10","observacions":"Evolució favorable","pla_seguiment":"Revisió en 30 dies"}', true),

-- 021 Intervenció tècnica (field_service)
('71000000-0000-0000-0000-000000000021','70000000-0000-0000-0000-000000000021','ca','text/html',NULL,
 '<h1>Full d''intervenció tècnica</h1><p>Tècnic: {{ technician.full_name }} · Client: {{ client_signatory.display_name }}</p><p>Data: {{ data_intervencio | date: "%d/%m/%Y" }} · Lloc: {{ adreca }}</p><p>Treballs: {{ descripcio_treballs }}</p><p>Materials: {{ materials | default: "—" }}</p><signature-field role="technician"></signature-field><signature-field role="client_signatory"></signature-field>',
 '{"data_intervencio":{"type":"date","label":"Data","required":true,"order":0},"adreca":{"type":"string","label":"Adreça","required":true,"order":1},"descripcio_treballs":{"type":"string","label":"Treballs realitzats","required":true,"order":2},"materials":{"type":"string","label":"Materials","required":false,"order":3}}',
 '{"technician":{"entity_type":"employee","label":"Tècnic/a","order":0,"for_signing":true},"client_signatory":{"entity_type":"contact","label":"Client","order":1,"for_signing":true}}',
 '{"data_intervencio":"2026-03-10","adreca":"C/ Exemple 1","descripcio_treballs":"Reparació instal·lació","materials":"Canonades"}', true),

-- 022 Pressupost obra
('71000000-0000-0000-0000-000000000022','70000000-0000-0000-0000-000000000022','ca','text/html',NULL,
 '<h1>Pressupost</h1><p>Client: {{ client_signatory.display_name }} · Data: {{ data_pressupost | date: "%d/%m/%Y" }}</p><p>Concepte: {{ concepte }}</p><p>Import: <strong>{{ import_total }} EUR</strong> (IVA {{ iva | default: "21" }}%)</p><p>Validesa: {{ validesa_dies }} dies.</p><signature-field role="client_signatory"></signature-field>',
 '{"data_pressupost":{"type":"date","label":"Data pressupost","required":true,"order":0},"concepte":{"type":"string","label":"Concepte","required":true,"order":1},"import_total":{"type":"number","label":"Import total (EUR)","required":true,"order":2},"iva":{"type":"number","label":"IVA %","required":false,"order":3},"validesa_dies":{"type":"number","label":"Dies validesa","required":true,"order":4}}',
 '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable","order":1,"for_signing":false}}',
 '{"data_pressupost":"2026-03-10","concepte":"Instal·lació climatització","import_total":"4500","iva":"21","validesa_dies":"30"}', true),

-- 023 Certificat finalització
('71000000-0000-0000-0000-000000000023','70000000-0000-0000-0000-000000000023','ca','text/html',NULL,
 '<h1>Certificat de finalització</h1><p>Certifiquem que els treballs «{{ descripcio }}» han finalitzat el <strong>{{ data_fi | date: "%d/%m/%Y" }}</strong> a {{ adreca }}.</p><p>Client: {{ client_signatory.display_name }}</p><signature-field role="technician"></signature-field><signature-field role="client_signatory"></signature-field>',
 '{"descripcio":{"type":"string","label":"Descripció treballs","required":true,"order":0},"data_fi":{"type":"date","label":"Data finalització","required":true,"order":1},"adreca":{"type":"string","label":"Adreça","required":true,"order":2}}',
 '{"technician":{"entity_type":"employee","label":"Tècnic/a","order":0,"for_signing":true},"client_signatory":{"entity_type":"contact","label":"Client","order":1,"for_signing":true}}',
 '{"descripcio":"Instal·lació completa","data_fi":"2026-03-15","adreca":"C/ Exemple 1"}', true),

-- 024 Reserva esdeveniment
('71000000-0000-0000-0000-000000000024','70000000-0000-0000-0000-000000000024','ca','text/html',NULL,
 '<h1>Reserva d''esdeveniment</h1><p>Client: {{ client_signatory.display_name }} · Data esdeveniment: {{ data_esdeveniment | date: "%d/%m/%Y" }}</p><p>Horari: {{ horari }} · Persones: {{ num_persones }} · Menú: {{ menu | default: "—" }}</p><p>Import: {{ import_reserva }} EUR</p><signature-field role="client_signatory"></signature-field>',
 '{"data_esdeveniment":{"type":"date","label":"Data esdeveniment","required":true,"order":0},"horari":{"type":"string","label":"Horari","required":true,"order":1},"num_persones":{"type":"number","label":"Nombre persones","required":true,"order":2},"menu":{"type":"string","label":"Menú","required":false,"order":3},"import_reserva":{"type":"number","label":"Import reserva (EUR)","required":true,"order":4}}',
 '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable","order":1,"for_signing":false}}',
 '{"data_esdeveniment":"2026-06-20","horari":"20:00-01:00","num_persones":"40","menu":"Menú degustació","import_reserva":"3200"}', true),

-- 025 Comanda càtering (intern)
('71000000-0000-0000-0000-000000000025','70000000-0000-0000-0000-000000000025','ca','text/html',NULL,
 '<h1>Comanda de càtering</h1><p>Esdeveniment: {{ nom_esdeveniment }} · Data lliurament: {{ data_lliurament | date: "%d/%m/%Y" }} {{ hora_lliurament }}</p><p>Detall: {{ detall_comanda }}</p><p>Responsable: {{ worker.full_name }}</p>',
 '{"nom_esdeveniment":{"type":"string","label":"Nom esdeveniment","required":true,"order":0},"data_lliurament":{"type":"date","label":"Data lliurament","required":true,"order":1},"hora_lliurament":{"type":"string","label":"Hora","required":true,"order":2},"detall_comanda":{"type":"string","label":"Detall comanda","required":true,"order":3}}',
 '{"worker":{"entity_type":"employee","label":"Responsable","order":0,"for_signing":false}}',
 '{"nom_esdeveniment":"Boda Garcia","data_lliurament":"2026-06-20","hora_lliurament":"18:00","detall_comanda":"120 racions"}', true),

-- 026 Ordre reparació
('71000000-0000-0000-0000-000000000026','70000000-0000-0000-0000-000000000026','ca','text/html',NULL,
 '<h1>Ordre de reparació</h1><p>Client: {{ client_signatory.display_name }} · Equip: {{ descripcio_equip }}</p><p>Avaria: {{ avaria }} · Data recepció: {{ data_recepcio | date: "%d/%m/%Y" }}</p><p>Pressupost estimat: {{ pressupost_estimat | default: "Pendent" }} EUR</p><signature-field role="client_signatory"></signature-field>',
 '{"descripcio_equip":{"type":"string","label":"Descripció equip","required":true,"order":0},"avaria":{"type":"string","label":"Avaria","required":true,"order":1},"data_recepcio":{"type":"date","label":"Data recepció","required":true,"order":2},"pressupost_estimat":{"type":"number","label":"Pressupost estimat (EUR)","required":false,"order":3}}',
 '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true},"technician":{"entity_type":"employee","label":"Tècnic","order":1,"for_signing":false}}',
 '{"descripcio_equip":"Bicicleta MTB","avaria":"Canvi trencat","data_recepcio":"2026-03-10","pressupost_estimat":"85"}', true),

-- 027 Pressupost reparació
('71000000-0000-0000-0000-000000000027','70000000-0000-0000-0000-000000000027','ca','text/html',NULL,
 '<h1>Pressupost de reparació</h1><p>Client: {{ client_signatory.display_name }} · Equip: {{ descripcio_equip }}</p><p>Import: {{ import_total }} EUR · Validesa: {{ validesa_dies }} dies</p><signature-field role="client_signatory"></signature-field>',
 '{"descripcio_equip":{"type":"string","label":"Equip","required":true,"order":0},"import_total":{"type":"number","label":"Import (EUR)","required":true,"order":1},"validesa_dies":{"type":"number","label":"Dies validesa","required":true,"order":2}}',
 '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
 '{"descripcio_equip":"Bicicleta MTB","import_total":"85","validesa_dies":"15"}', true),

-- 028 Certificat lliurament
('71000000-0000-0000-0000-000000000028','70000000-0000-0000-0000-000000000028','ca','text/html',NULL,
 '<h1>Certificat de lliurament</h1><p>Lliurem a {{ client_signatory.display_name }} l''equip: {{ descripcio_equip }}.</p><p>Data: {{ data_lliurament | date: "%d/%m/%Y" }} · Import cobrat: {{ import_cobrat | default: "0" }} EUR</p><signature-field role="client_signatory"></signature-field>',
 '{"descripcio_equip":{"type":"string","label":"Equip","required":true,"order":0},"data_lliurament":{"type":"date","label":"Data lliurament","required":true,"order":1},"import_cobrat":{"type":"number","label":"Import cobrat (EUR)","required":false,"order":2}}',
 '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true},"technician":{"entity_type":"employee","label":"Tècnic","order":1,"for_signing":false}}',
 '{"descripcio_equip":"Bicicleta MTB","data_lliurament":"2026-03-12","import_cobrat":"85"}', true)
ON CONFLICT (id) DO NOTHING;

-- Prefix 72: document_templates  (001-028, template_type='docx')
-- Prefix 73: document_template_locales (001-028, locale='ca', mime=docx)
-- Generat amb: cd scripts && node generate-docx-seed.mjs

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
  ('72000000-0000-0000-0000-000000000016', NULL, 'Carta d''advertència laboral', 'Comunicació formal d''advertència o amonestació a l''empleat/da.', 'hr', 'docx', true, true, NULL, ARRAY['generic','practice','hospitality','workshop_maker']),
  ('72000000-0000-0000-0000-000000000017', NULL, 'Acord de teletreball', 'Acord individual de treball a distància.', 'hr', 'docx', true, true, NULL, ARRAY['generic','practice']),
  ('72000000-0000-0000-0000-000000000018', NULL, 'Consentiment informat', 'Full de consentiment informat per a actes o tractaments.', 'legal', 'docx', true, true, NULL, ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000019', NULL, 'Full d''admissió de pacient/client', 'Obertura d''expedient amb dades del pacient o client.', 'operations', 'docx', true, true, NULL, ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000020', NULL, 'Informe de visita o sessió', 'Registre intern de visita professional (sense signatura).', 'operations', 'docx', true, true, NULL, ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000021', NULL, 'Full d''intervenció tècnica', 'Acta d''intervenció a domicili o instal·lació del client.', 'operations', 'docx', true, true, NULL, ARRAY['field_service']),
  ('72000000-0000-0000-0000-000000000022', NULL, 'Pressupost d''obra o instal·lació', 'Oferta econòmica per a client amb acceptació per signatura.', 'commercial', 'docx', true, true, NULL, ARRAY['field_service','workshop_maker']),
  ('72000000-0000-0000-0000-000000000023', NULL, 'Certificat de finalització de treballs', 'Certificació de treballs completats amb signatura del client.', 'operations', 'docx', true, true, NULL, ARRAY['field_service']),
  ('72000000-0000-0000-0000-000000000024', NULL, 'Contracte de reserva d''esdeveniment', 'Reserva de sala o esdeveniment privat amb signatura del client.', 'commercial', 'docx', true, true, NULL, ARRAY['hospitality']),
  ('72000000-0000-0000-0000-000000000025', NULL, 'Full de comanda de càtering', 'Comanda interna de càtering (sense signatura).', 'operations', 'docx', true, true, NULL, ARRAY['hospitality']),
  ('72000000-0000-0000-0000-000000000026', NULL, 'Ordre de reparació', 'Recepció d''equipament o vehicle amb signatura del client.', 'operations', 'docx', true, true, NULL, ARRAY['workshop_maker']),
  ('72000000-0000-0000-0000-000000000027', NULL, 'Pressupost de reparació', 'Pressupost amb acceptació del client.', 'commercial', 'docx', true, true, NULL, ARRAY['workshop_maker']),
  ('72000000-0000-0000-0000-000000000028', NULL, 'Certificat de lliurament', 'Lliurament d''equip reparat amb signatura del client.', 'operations', 'docx', true, true, NULL, ARRAY['workshop_maker'])
ON CONFLICT DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
(
  '73000000-0000-0000-0000-000000000016', '72000000-0000-0000-0000-000000000016', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/16-carta-advertencia-ca.docx', NULL,
  '{"data_avis":{"type":"date","label":"Data de l''advertència","required":true,"order":0},"descripcio_incidencia":{"type":"string","label":"Descripció incidència","required":true,"order":1},"motiu":{"type":"string","label":"Motiu","required":true,"order":2},"gravetat":{"type":"string","label":"Gravetat","required":false,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"data_avis":"2026-03-01","descripcio_incidencia":"Retards reiterats","motiu":"Incompliment horari","gravetat":"lleu"}',
  true
),
(
  '73000000-0000-0000-0000-000000000017', '72000000-0000-0000-0000-000000000017', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/17-acord-teletreball-ca.docx', NULL,
  '{"data_inici":{"type":"date","label":"Data d''inici","required":true,"order":0},"dies_tele":{"type":"string","label":"Dies de teletreball","required":true,"order":1},"horari":{"type":"string","label":"Horari","required":true,"order":2},"lloc_treball":{"type":"string","label":"Lloc de treball","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"data_inici":"2026-04-01","dies_tele":"Dl-Dv","horari":"9-18h","lloc_treball":"Domicili"}',
  true
),
(
  '73000000-0000-0000-0000-000000000018', '72000000-0000-0000-0000-000000000018', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/18-consentiment-informat-ca.docx', NULL,
  '{"procediment":{"type":"string","label":"Procediment","required":true,"order":0},"data_consentiment":{"type":"date","label":"Data","required":true,"order":1}}',
  '{"client_signatory":{"entity_type":"contact","label":"Pacient/Client","order":0,"for_signing":true}}',
  '{"procediment":"Tractament dental rutinari","data_consentiment":"2026-03-10"}',
  true
),
(
  '73000000-0000-0000-0000-000000000019', '72000000-0000-0000-0000-000000000019', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/19-full-admissio-ca.docx', NULL,
  '{"motiu":{"type":"string","label":"Motiu consulta","required":true,"order":0},"antecedents":{"type":"string","label":"Antecedents","required":false,"order":1},"data_admissio":{"type":"date","label":"Data admissió","required":true,"order":2}}',
  '{"client_signatory":{"entity_type":"contact","label":"Pacient/Client","order":0,"for_signing":true}}',
  '{"motiu":"Primera visita","antecedents":"","data_admissio":"2026-03-10"}',
  true
),
(
  '73000000-0000-0000-0000-000000000020', '72000000-0000-0000-0000-000000000020', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/20-informe-visita-ca.docx', NULL,
  '{"data_visita":{"type":"date","label":"Data visita","required":true,"order":0},"observacions":{"type":"string","label":"Observacions","required":true,"order":1},"pla_seguiment":{"type":"string","label":"Pla de seguiment","required":false,"order":2}}',
  '{}',
  '{"data_visita":"2026-03-10","observacions":"Evolució favorable","pla_seguiment":"Revisió en 30 dies"}',
  true
),
(
  '73000000-0000-0000-0000-000000000021', '72000000-0000-0000-0000-000000000021', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/21-intervencio-tecnica-ca.docx', NULL,
  '{"data_intervencio":{"type":"date","label":"Data","required":true,"order":0},"adreca":{"type":"string","label":"Adreça","required":true,"order":1},"descripcio_treballs":{"type":"string","label":"Treballs","required":true,"order":2},"materials":{"type":"string","label":"Materials","required":false,"order":3}}',
  '{"technician":{"entity_type":"employee","label":"Tècnic/a","order":0,"for_signing":true},"client_signatory":{"entity_type":"contact","label":"Client","order":1,"for_signing":true}}',
  '{"data_intervencio":"2026-03-10","adreca":"C/ Exemple 1","descripcio_treballs":"Reparació instal·lació","materials":"Canonades"}',
  true
),
(
  '73000000-0000-0000-0000-000000000022', '72000000-0000-0000-0000-000000000022', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/22-pressupost-obra-ca.docx', NULL,
  '{"data_pressupost":{"type":"date","label":"Data","required":true,"order":0},"concepte":{"type":"string","label":"Concepte","required":true,"order":1},"import_total":{"type":"number","label":"Import (EUR)","required":true,"order":2},"validesa_dies":{"type":"number","label":"Dies validesa","required":true,"order":3}}',
  '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
  '{"data_pressupost":"2026-03-10","concepte":"Instal·lació climatització","import_total":"4500","validesa_dies":"30"}',
  true
),
(
  '73000000-0000-0000-0000-000000000023', '72000000-0000-0000-0000-000000000023', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/23-certificat-finalitzacio-ca.docx', NULL,
  '{"descripcio":{"type":"string","label":"Descripció","required":true,"order":0},"data_fi":{"type":"date","label":"Data finalització","required":true,"order":1},"adreca":{"type":"string","label":"Adreça","required":true,"order":2}}',
  '{"technician":{"entity_type":"employee","label":"Tècnic/a","order":0,"for_signing":true},"client_signatory":{"entity_type":"contact","label":"Client","order":1,"for_signing":true}}',
  '{"descripcio":"Instal·lació completa","data_fi":"2026-03-15","adreca":"C/ Exemple 1"}',
  true
),
(
  '73000000-0000-0000-0000-000000000024', '72000000-0000-0000-0000-000000000024', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/24-reserva-esdeveniment-ca.docx', NULL,
  '{"data_esdeveniment":{"type":"date","label":"Data esdeveniment","required":true,"order":0},"horari":{"type":"string","label":"Horari","required":true,"order":1},"num_persones":{"type":"number","label":"Persones","required":true,"order":2},"import_reserva":{"type":"number","label":"Import (EUR)","required":true,"order":3}}',
  '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
  '{"data_esdeveniment":"2026-06-20","horari":"20:00-01:00","num_persones":"40","import_reserva":"3200"}',
  true
),
(
  '73000000-0000-0000-0000-000000000025', '72000000-0000-0000-0000-000000000025', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/25-comanda-catering-ca.docx', NULL,
  '{"nom_esdeveniment":{"type":"string","label":"Esdeveniment","required":true,"order":0},"data_lliurament":{"type":"date","label":"Data lliurament","required":true,"order":1},"detall_comanda":{"type":"string","label":"Detall","required":true,"order":2}}',
  '{"worker":{"entity_type":"employee","label":"Responsable","order":0,"for_signing":false}}',
  '{"nom_esdeveniment":"Boda Garcia","data_lliurament":"2026-06-20","detall_comanda":"120 racions"}',
  true
),
(
  '73000000-0000-0000-0000-000000000026', '72000000-0000-0000-0000-000000000026', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/26-ordre-reparacio-ca.docx', NULL,
  '{"descripcio_equip":{"type":"string","label":"Equip","required":true,"order":0},"avaria":{"type":"string","label":"Avaria","required":true,"order":1},"data_recepcio":{"type":"date","label":"Data recepció","required":true,"order":2}}',
  '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
  '{"descripcio_equip":"Bicicleta MTB","avaria":"Canvi trencat","data_recepcio":"2026-03-10"}',
  true
),
(
  '73000000-0000-0000-0000-000000000027', '72000000-0000-0000-0000-000000000027', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/27-pressupost-reparacio-ca.docx', NULL,
  '{"descripcio_equip":{"type":"string","label":"Equip","required":true,"order":0},"import_total":{"type":"number","label":"Import (EUR)","required":true,"order":1},"validesa_dies":{"type":"number","label":"Dies validesa","required":true,"order":2}}',
  '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
  '{"descripcio_equip":"Bicicleta MTB","import_total":"85","validesa_dies":"15"}',
  true
),
(
  '73000000-0000-0000-0000-000000000028', '72000000-0000-0000-0000-000000000028', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'platform/docx/28-certificat-lliurament-ca.docx', NULL,
  '{"descripcio_equip":{"type":"string","label":"Equip","required":true,"order":0},"data_lliurament":{"type":"date","label":"Data lliurament","required":true,"order":1},"import_cobrat":{"type":"number","label":"Import cobrat (EUR)","required":false,"order":2}}',
  '{"client_signatory":{"entity_type":"contact","label":"Client","order":0,"for_signing":true}}',
  '{"descripcio_equip":"Bicicleta MTB","data_lliurament":"2026-03-12","import_cobrat":"85"}',
  true
)
ON CONFLICT DO NOTHING;

-- ── default_block_mapping (consolidat) ─────────────────────────────────────
-- real header/footer blocks in the final rendering path.

DO $$
BEGIN
  -- Generic HTML platform templates: ensure the standard footer and body blocks exist.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category NOT IN ('hr', 'rrhh', 'legal', 'rgpd', 'gdpr', 'iso', 'qualitat', 'quality', 'safety');

  -- HR templates: use the HR-specific header + body mappings.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000012',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000021',
    'document_footer', 'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('hr', 'rrhh');

  -- ISO / quality / safety templates: use the standard page header plus legal footer.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000011',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('iso', 'qualitat', 'quality', 'safety');

  -- Legal / RGPD templates: use the legal header/footer defaults.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000010',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('legal', 'rgpd', 'gdpr');
END $$;
