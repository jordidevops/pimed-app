-- =============================================================================
-- Migration: 20260530000001_fix_platform_templates_variables_role.sql
-- Propòsit:  Actualitzar les plantilles HTML de plataforma per suportar
--            auto-fill de variables en dos enfocaments:
--
--   A) Schema-based (plantilles 1-3, 8-10, 12):
--      · Reanomena les claus de variables al nom del camp DB equivalent
--        (nom_treballador → full_name, dni → document_id, carrec → job_title).
--      · Afegeix el camp "role" a les variables d'entitat.
--      · L'usuari veu el camp pre-omplert i el pot editar.
--
--   B) Path-based (plantilles 4, 5, 6, 13):
--      · Reemplaça {{nom_treballador}} per {{Treballador.full_name}} a l'HTML.
--      · Elimina l'entrada de la variable del schema (es resol automàticament
--        des del role assignment al DocumentOrchestrator).
--      · L'usuari no veu cap camp de formulari per al nom.
--
-- Idempotència: cada UPDATE comprova l'estat actual (LIKE '%{{nom_treballador}}%')
--               i no fa res si la migració ja s'ha aplicat.
-- Afecta: ÚNICAMENT plantilles de plataforma (tenant_id IS NULL).
-- =============================================================================

-- ── Plantilla 1: Contracte de Treball ── Enfocament A ──────────────────────
UPDATE data.document_template_locales
SET
  html_content = replace(replace(replace(
    html_content,
    '{{nom_treballador}}', '{{full_name}}'),
    '{{dni}}',             '{{document_id}}'),
    '{{carrec}}',          '{{job_title}}'
  ),
  variables_schema = jsonb_build_object(
    'full_name',     jsonb_build_object('type','string','label','Nom del treballador/a','required',true, 'role','Treballador','order',0),
    'document_id',   jsonb_build_object('type','string','label','DNI/NIE',             'required',true, 'role','Treballador','order',1),
    'job_title',     jsonb_build_object('type','string','label','Càrrec',              'required',true, 'role','Treballador','order',2),
    'data_inici',    jsonb_build_object('type','date',  'label','Data d''incorporació','required',true, 'order',3),
    'salari_anual',  jsonb_build_object('type','number','label','Salari brut anual (EUR)','required',true,'order',4),
    'jornada_hores', jsonb_build_object('type','number','label','Hores setmanals',     'required',true, 'order',5)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000001'
  AND html_content LIKE '%{{nom_treballador}}%';  -- idempotència

-- ── Plantilla 2: Sol·licitud de Vacances ── Enfocament A ───────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{full_name}}'),
  variables_schema = jsonb_build_object(
    'full_name',  jsonb_build_object('type','string','label','Nom del treballador/a','required',true, 'role','Treballador','order',0),
    'data_inici', jsonb_build_object('type','date',  'label','Data inici vacances',  'required',true, 'order',1),
    'data_fi',    jsonb_build_object('type','date',  'label','Data fi vacances',     'required',true, 'order',2),
    'dies',       jsonb_build_object('type','number','label','Dies laborables',      'required',true, 'order',3),
    'data_sol',   jsonb_build_object('type','date',  'label','Data sol·licitud',     'required',true, 'order',4)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000002'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 3: Canvi de Jornada ── Enfocament A ──────────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{full_name}}'),
  variables_schema = jsonb_build_object(
    'full_name',    jsonb_build_object('type','string','label','Nom del treballador/a','required',true, 'role','Treballador','order',0),
    'nova_jornada', jsonb_build_object('type','number','label','Nova jornada (h/setmana)','required',true,'order',1),
    'motiu',        jsonb_build_object('type','string','label','Motiu',                'required',true, 'order',2),
    'data_efecte',  jsonb_build_object('type','date',  'label','Data d''efecte',       'required',true, 'order',3)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000003'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 4: Acta EPI ── Enfocament B (path-based) ─────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{Treballador.full_name}}'),
  variables_schema = jsonb_build_object(
    'data_lliurament', jsonb_build_object('type','date',  'label','Data de lliurament','required',true,'order',0),
    'llista_epi',      jsonb_build_object('type','string','label','Llista EPI lliurats','required',true,'order',1)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000004'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 5: Confidencialitat ── Enfocament B ──────────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{Treballador.full_name}}'),
  variables_schema = jsonb_build_object(
    'data', jsonb_build_object('type','date','label','Data de signatura','required',true,'order',0)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000005'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 6: Avançament de Nòmina ── Enfocament B ─────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{Treballador.full_name}}'),
  variables_schema = jsonb_build_object(
    'import_sol', jsonb_build_object('type','number','label','Import sol·licitat (EUR)','required',true, 'order',0),
    'motiu',      jsonb_build_object('type','string','label','Motiu',                  'required',false,'order',1)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000006'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 8: Revisió Salarial ── Enfocament A ──────────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{full_name}}'),
  variables_schema = jsonb_build_object(
    'full_name',     jsonb_build_object('type','string','label','Nom del treballador/a','required',true, 'role','Treballador','order',0),
    'salari_actual', jsonb_build_object('type','number','label','Salari actual (EUR/any)','required',true,'order',1),
    'nou_salari',    jsonb_build_object('type','number','label','Nou salari (EUR/any)', 'required',true, 'order',2),
    'percentatge',   jsonb_build_object('type','number','label','Increment (%)',        'required',true, 'order',3),
    'data_efecte',   jsonb_build_object('type','date',  'label','Data d''efecte',       'required',true, 'order',4)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000008'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 9: Cessió Equipament ── Enfocament A ─────────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{full_name}}'),
  variables_schema = jsonb_build_object(
    'full_name',            jsonb_build_object('type','string','label','Nom del treballador/a','required',true, 'role','Treballador','order',0),
    'nom_equip',            jsonb_build_object('type','string','label','Nom de l''equip',      'required',true, 'order',1),
    'num_serie',            jsonb_build_object('type','string','label','Número de sèrie',      'required',false,'order',2),
    'data_cessio',          jsonb_build_object('type','date',  'label','Data de cessió',       'required',true, 'order',3),
    'data_retorn_prevista', jsonb_build_object('type','date',  'label','Data retorn prevista', 'required',true, 'order',4)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000009'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 10: Autorització Accés ── Enfocament A ───────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{full_name}}'),
  variables_schema = jsonb_build_object(
    'full_name',     jsonb_build_object('type','string','label','Nom del treballador/a','required',true,'role','Treballador','order',0),
    'nom_client',    jsonb_build_object('type','string','label','Nom del client',       'required',true,'order',1),
    'adreca_client', jsonb_build_object('type','string','label','Adreça del client',    'required',true,'order',2),
    'data_acces',    jsonb_build_object('type','date',  'label','Data d''accés',        'required',true,'order',3)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000010'
  AND html_content LIKE '%{{nom_treballador}}%';

-- ── Plantilla 12: Traspàs de Funcions ── Enfocament A (afegir "role" al schema) ──
UPDATE data.document_template_locales
SET
  variables_schema = jsonb_build_object(
    'nom_cedent',           jsonb_build_object('type','string','label','Nom del cedent',   'required',true,'role','Cedent',  'order',0),
    'nom_receptor',         jsonb_build_object('type','string','label','Nom del receptor', 'required',true,'role','Receptor','order',1),
    'funcions_traspassades',jsonb_build_object('type','string','label','Funcions traspassades','required',true,'order',2),
    'data_traspas',         jsonb_build_object('type','date',  'label','Data de traspàs',  'required',true,'order',3)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000012'
  AND NOT (variables_schema -> 'nom_cedent' ? 'role');  -- idempotència

-- ── Plantilla 13: RGPD ── Enfocament B (path-based) ───────────────────────
UPDATE data.document_template_locales
SET
  html_content     = replace(html_content, '{{nom_treballador}}', '{{Treballador.full_name}}'),
  variables_schema = jsonb_build_object(
    'data', jsonb_build_object('type','date','label','Data','required',true,'order',0)
  ),
  updated_at = now()
WHERE id = '71000000-0000-0000-0000-000000000013'
  AND html_content LIKE '%{{nom_treballador}}%';



