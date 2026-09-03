-- ─── B4. Plantilles de documents HTML ────────────────────────────────────────
-- Prefix 70: document_templates  (001-007 plataforma, 008-014 Acme Corp, 015 Test de firmes)
-- Prefix 71: document_template_locales (001-015, locale='ca', mime=text/html)

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by)
VALUES
  ('70000000-0000-0000-0000-000000000001', NULL,                                   'Contracte de treball indefinit',       'Contracte estàndard per a noves incorporacions.',             'hr',         'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', NULL,                                   'Sol·licitud de vacances',              'Formulari de sol·licitud de vacances anuals.',                'hr',         'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000003', NULL,                                   'Sol·licitud canvi de jornada',         'Petició formal de canvi de distribució horària.',             'hr',         'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000004', NULL,                                   'Acta de lliurament d''EPI',            'Acta de recepció d''equips de protecció individual.',         'safety',     'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000005', NULL,                                   'Declaració de confidencialitat',       'Acord de confidencialitat i no-divulgació.',                  'legal',      'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000006', NULL,                                   'Sol·licitud d''avançament salarial',   'Petició d''avançament sobre nòmina futura.',                 'hr',         'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000007', NULL,                                   'Butlletí d''acollida',                 'Document informatiu per a nous treballadors (generar i lliurar).','hr',   'html', true,  true, '20000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'Annexe revisió salarial anual',        'Comunicació formal de revisió de salari.',                    'hr',         'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Cessió temporal d''equipament',        'Acta de cessió d''eines o dispositius.',                      'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'Autorització accés a instal·lació',    'Autorització per treballar a instal·lacions de client.',      'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', 'Informe d''incident tècnic',           'Registre intern d''incidents (generar i arxivar).',           'safety',     'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', 'Acta de traspàs de funcions',          'Formalitza el traspàs de funcions entre dos treballadors.',   'hr',         'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', 'Nota informativa RGPD',                'Informació al treballador sobre tractament de dades.',        'legal',      'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', 'Informe de seguiment setmanal',        'Resum d''activitats setmanals per a direcció.',               'operations', 'html', false, true, '20000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000015', NULL,                                   'Test de firmes',                       'Document de referència per a proves de signatura (DocuSeal i firma pròpia).', 'signing', 'html', true, true, '20000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

-- ─── Plantilles HTML: variables_schema i sintaxi de variables ───────────────
-- Dos enfocaments conviuen:
--   A) Schema-based: clau = camp DB (full_name, document_id, job_title) + "role" → l'usuari veu el camp pre-omplert i pot editar-lo.
--   B) Path-based:  {{Rol.camp}} directament a l'HTML → resolt automàticament des del role assignment, l'usuari no veu cap camp de formulari.
-- Plantilles 1-3, 8-10, 12 → enfocament A.  Plantilles 4, 5, 6, 13 → enfocament B.
INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
VALUES
-- ── Plantilla 1: Contracte de Treball ── Enfocament A (schema-based, claus = camps DB + role) ──
(
  '71000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001','ca','text/html',NULL,
  '<h1>Contracte de Treball Indefinit</h1><p>Entre l''empresa <strong>Acme Corp S.A.</strong> i el/la treballador/a <strong>{{full_name}}</strong>, DNI <strong>{{document_id}}</strong>.</p><p>Data d''incorporació: <strong>{{data_inici}}</strong>. Càrrec: <strong>{{job_title}}</strong>.</p><p>Salari brut anual: <strong>{{salari_anual}} EUR</strong>. Jornada: <strong>{{jornada_hores}} h/setmana</strong>.</p><p>Les parts signen de conformitat amb la legislació laboral vigent.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"document_id":{"type":"string","label":"DNI/NIE","required":true,"role":"worker","order":1},"job_title":{"type":"string","label":"Càrrec","required":true,"role":"worker","order":2},"data_inici":{"type":"date","label":"Data d''incorporació","required":true,"order":3},"salari_anual":{"type":"number","label":"Salari brut anual (EUR)","required":true,"order":4},"jornada_hores":{"type":"number","label":"Hores setmanals","required":true,"order":5}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Maria Garcia Lopez","document_id":"12345678A","job_title":"Tecnic/a","data_inici":"2025-09-01","salari_anual":"28000","jornada_hores":"40"}',
  true
),
-- ── Plantilla 2: Sol·licitud de Vacances ── Enfocament A ──
(
  '71000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000002','ca','text/html',NULL,
  '<h1>Sol·licitud de Vacances</h1><p>El/la treballador/a <strong>{{full_name}}</strong> sol·licita vacances del <strong>{{data_inici}}</strong> al <strong>{{data_fi}}</strong> (<strong>{{dies}}</strong> dies laborables).</p><p>Data sol·licitud: <strong>{{data_sol}}</strong>.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data_inici":{"type":"date","label":"Data inici vacances","required":true,"order":1},"data_fi":{"type":"date","label":"Data fi vacances","required":true,"order":2},"dies":{"type":"number","label":"Dies laborables","required":true,"order":3},"data_sol":{"type":"date","label":"Data sol·licitud","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"direct_manager":{"entity_type":"employee","label":"Cap immediat","order":1,"for_signing":true}}',
  '{"full_name":"Marc Vila Bosch","data_inici":"2025-08-01","data_fi":"2025-08-15","dies":"11","data_sol":"2025-06-15"}',
  true
),
-- ── Plantilla 3: Canvi de Jornada ── Enfocament A ──
(
  '71000000-0000-0000-0000-000000000003','70000000-0000-0000-0000-000000000003','ca','text/html',NULL,
  '<h1>Sol·licitud de Canvi de Jornada</h1><p>El/la treballador/a <strong>{{full_name}}</strong> sol·licita modificar la seva jornada a <strong>{{nova_jornada}}</strong> hores setmanals, amb efectes des del <strong>{{data_efecte}}</strong>.</p><p>Motiu: {{motiu}}.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nova_jornada":{"type":"number","label":"Nova jornada (h/setmana)","required":true,"order":1},"motiu":{"type":"string","label":"Motiu","required":true,"order":2},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":1,"for_signing":true}}',
  '{"full_name":"Laia Torres Serra","nova_jornada":"32","motiu":"Conciliacio familiar","data_efecte":"2025-10-01"}',
  true
),
-- ── Plantilla 4: Acta EPI ── Enfocament B (path-based: {{Treballador.full_name}} auto-resolt) ──
(
  '71000000-0000-0000-0000-000000000004','70000000-0000-0000-0000-000000000004','ca','text/html',NULL,
  '{{ document_header }}<h1>Acta de Lliurament d''EPI</h1><p>En data <strong>{{data_lliurament}}</strong> s''han lliurat al/a la treballador/a <strong>{{worker.full_name}}</strong> els EPI: <strong>{{llista_epi}}</strong>.</p><p>El/la treballador/a es compromet a usar-los correctament i comunicar qualsevol deficiència.</p>{{ document_footer }}',
  '{"data_lliurament":{"type":"date","label":"Data de lliurament","required":true,"order":0},"llista_epi":{"type":"string","label":"Llista EPI lliurats","required":true,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"safety_supervisor":{"entity_type":"employee","label":"Supervisor/a PRL","order":1,"for_signing":true,"auto_assign_current_user":true}}',
  '{"data_lliurament":"2025-07-01","llista_epi":"Casc, guants, ulleres, botes de seguretat"}',
  true
),
-- ── Plantilla 5: Confidencialitat ── Enfocament B (path-based) ──
(
  '71000000-0000-0000-0000-000000000005','70000000-0000-0000-0000-000000000005','ca','text/html',NULL,
  '<h1>Declaració de Confidencialitat i No-Divulgació</h1><p>Jo, <strong>{{worker.full_name}}</strong>, em comprometo a mantenir en estricta confidencialitat tota la informació reservada a la qual accedeixi en les meves funcions. Aquesta obligació es manté indefinidament un cop extingida la relació laboral.</p><p>Signat a Barcelona, a <strong>{{data}}</strong>.</p>',
  '{"data":{"type":"date","label":"Data de signatura","required":true,"order":0}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true}}',
  '{"data":"2025-07-15"}',
  true
),
-- ── Plantilla 6: Avançament de Nòmina ── Enfocament B (path-based, mixed: nom auto + import manual) ──
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
-- ── Plantilla 8: Revisió Salarial ── Enfocament A ──
(
  '71000000-0000-0000-0000-000000000008','70000000-0000-0000-0000-000000000008','ca','text/html',NULL,
  '<h1>Annexe: Revisió Salarial Anual</h1><p>S''informa a <strong>{{full_name}}</strong> que des del <strong>{{data_efecte}}</strong> el salari brut anual passa de <strong>{{salari_actual}} EUR</strong> a <strong>{{nou_salari}} EUR</strong> (increment del <strong>{{percentatge}}%</strong>). La present comunicació constitueix un annex al contracte vigent.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"salari_actual":{"type":"number","label":"Salari actual (EUR/any)","required":true,"order":1},"nou_salari":{"type":"number","label":"Nou salari (EUR/any)","required":true,"order":2},"percentatge":{"type":"number","label":"Increment (%)","required":true,"order":3},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Director/a","order":1,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","salari_actual":"28000","nou_salari":"29400","percentatge":"5","data_efecte":"2026-01-01"}',
  true
),
-- ── Plantilla 9: Cessió Equipament ── Enfocament A ──
(
  '71000000-0000-0000-0000-000000000009','70000000-0000-0000-0000-000000000009','ca','text/html',NULL,
  '<h1>Acta de Cessió Temporal d''Equipament</h1><p>Es cedeix temporalment al/a la treballador/a <strong>{{full_name}}</strong> l''equipament <strong>{{nom_equip}}</strong> (num. serie: <strong>{{num_serie}}</strong>), del <strong>{{data_cessio}}</strong> fins al <strong>{{data_retorn_prevista}}</strong>. El treballador/a n''és responsable i el retornarà en bon estat.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_equip":{"type":"string","label":"Nom de l''equip","required":true,"order":1},"num_serie":{"type":"string","label":"Numero de serie","required":false,"order":2},"data_cessio":{"type":"date","label":"Data de cessió","required":true,"order":3},"data_retorn_prevista":{"type":"date","label":"Data retorn prevista","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"warehouse_manager":{"entity_type":"employee","label":"Responsable de magatzem","order":1,"for_signing":true}}',
  '{"full_name":"Sergi Costa Ribas","nom_equip":"Tauleta de camp ruggeditzada","num_serie":"SN-2024-0042","data_cessio":"2025-07-01","data_retorn_prevista":"2025-12-31"}',
  true
),
-- ── Plantilla 10: Autorització Accés ── Enfocament A ──
(
  '71000000-0000-0000-0000-000000000010','70000000-0000-0000-0000-000000000010','ca','text/html',NULL,
  '<h1>Autorització d''Acces a Instal·lació de Client</h1><p>S''autoritza al/a la treballador/a <strong>{{full_name}}</strong> per accedir a les instal·lacions de <strong>{{nom_client}}</strong> (adreca: <strong>{{adreca_client}}</strong>) el dia <strong>{{data_acces}}</strong>. L''accés es limita a les activitats del servei contractat.</p>',
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_client":{"type":"string","label":"Nom del client","required":true,"order":1},"adreca_client":{"type":"string","label":"Adreca del client","required":true,"order":2},"data_acces":{"type":"date","label":"Data d''acces","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"site_manager":{"entity_type":"employee","label":"Cap d''obra","order":1,"for_signing":true}}',
  '{"full_name":"Jordi Soler Mas","nom_client":"Constructora Meridian S.L.","adreca_client":"Carrer de la Industria 45, Barcelona","data_acces":"2025-07-10"}',
  true
),
(
  '71000000-0000-0000-0000-000000000011','70000000-0000-0000-0000-000000000011','ca','text/html',NULL,
  '<h1>Informe d''Incident Tecnic</h1><table><tr><th>Camp</th><th>Detall</th></tr><tr><td>Data</td><td>{{data_incident}}</td></tr><tr><td>Lloc</td><td>{{lloc}}</td></tr><tr><td>Descripcio</td><td>{{descripcio_incident}}</td></tr><tr><td>Mesures adoptades</td><td>{{mesures_adoptades}}</td></tr></table>',
  '{"data_incident":{"type":"date","label":"Data de l''incident","required":true,"order":0},"lloc":{"type":"string","label":"Lloc de l''incident","required":true,"order":1},"descripcio_incident":{"type":"string","label":"Descripcio de l''incident","required":true,"order":2},"mesures_adoptades":{"type":"string","label":"Mesures adoptades","required":true,"order":3}}',
  '{}',
  '{"data_incident":"2025-06-20","lloc":"Sala quadres electrics, planta 2","descripcio_incident":"Curtcircuit menor. Sense ferits.","mesures_adoptades":"Substitucio fusibles. Notificacio al responsable."}',
  true
),
-- ── Plantilla 12: Traspàs de Funcions ── Enfocament A (afegir camp "role" als signants) ──
(
  '71000000-0000-0000-0000-000000000012','70000000-0000-0000-0000-000000000012','ca','text/html',NULL,
  '<h1>Acta de Traspass de Funcions</h1><p><strong>{{nom_cedent}}</strong> fa traspass formal de funcions a <strong>{{nom_receptor}}</strong> amb efectes des del <strong>{{data_traspas}}</strong>. Funcions traspassades: <strong>{{funcions_traspassades}}</strong>. Ambdues parts confirmen que el traspass s''ha efectuat de manera completa.</p>',
  '{"nom_cedent":{"type":"string","label":"Nom del cedent","required":true,"role":"transferor","order":0},"nom_receptor":{"type":"string","label":"Nom del receptor","required":true,"role":"recipient","order":1},"funcions_traspassades":{"type":"string","label":"Funcions traspassades","required":true,"order":2},"data_traspas":{"type":"date","label":"Data de traspass","required":true,"order":3}}',
  '{"transferor":{"entity_type":"employee","label":"Cedent","order":0,"for_signing":true},"recipient":{"entity_type":"employee","label":"Receptor","order":1,"for_signing":true},"hr_manager":{"entity_type":"employee","label":"Responsable RRHH","order":2,"for_signing":true}}',
  '{"nom_cedent":"Susanna Ribas Carreras","nom_receptor":"Julia Montalba Safont","funcions_traspassades":"Coordinacio equip Gracia, gestio comandes i control magatzem","data_traspas":"2025-09-15"}',
  true
),
-- ── Plantilla 13: RGPD ── Enfocament B (path-based: {{Treballador.full_name}}) ──
(
  '71000000-0000-0000-0000-000000000013','70000000-0000-0000-0000-000000000013','ca','text/html',NULL,
  '<h1>Nota Informativa sobre Proteccio de Dades (RGPD)</h1><p>En compliment del Reglament (UE) 2016/679, s''informa a <strong>{{worker.full_name}}</strong> que les seves dades personals seran tractades per Acme Corp S.A. per gestionar la relacio laboral. Pot exercir els drets d''acces, rectificacio, supressio i portabilitat a rrhh@acme-corp.com.</p><p>Confirmo haver rebut la present informacio. Data: <strong>{{data}}</strong>.</p>',
  '{"data":{"type":"date","label":"Data","required":true,"order":0}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a (confirmacio recepcio)","order":0,"for_signing":true}}',
  '{"data":"2025-07-01"}',
  true
),
(
  '71000000-0000-0000-0000-000000000014','70000000-0000-0000-0000-000000000014','ca','text/html',NULL,
  '<h1>Informe de Seguiment Setmanal</h1><table><tr><th>Camp</th><th>Detall</th></tr><tr><td>Setmana</td><td>{{setmana}}</td></tr><tr><td>Responsable</td><td>{{responsable}}</td></tr><tr><td>Activitats</td><td>{{activitats}}</td></tr><tr><td>Observacions</td><td>{{observacions}}</td></tr></table>',
  '{"setmana":{"type":"string","label":"Setmana (ex: 2025-W28)","required":true,"order":0},"responsable":{"type":"string","label":"Responsable","required":true,"order":1},"activitats":{"type":"string","label":"Activitats realitzades","required":true,"order":2},"observacions":{"type":"string","label":"Observacions","required":false,"order":3}}',
  '{}',
  '{"setmana":"2025-W28","responsable":"Marta Rovira Figueras","activitats":"Revisio quadres electrics edifici A i B. Manteniment preventiu equips.","observacions":"Pendent reposicio peces quadre B."}',
  true
),
-- ── Plantilla 15: Test de Firmes — etiquetes DocuSeal per a proves de signatura ──
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
  ('72000000-0000-0000-0000-000000000001', NULL, 'Contracte de treball indefinit', 'Contracte estàndard per a noves incorporacions.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000002', NULL, 'Sol·licitud de vacances', 'Formulari de sol·licitud de vacances anuals.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000003', NULL, 'Sol·licitud canvi de jornada', 'Petició formal de canvi de distribució horària.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000004', NULL, 'Acta de lliurament d''EPI', 'Acta de recepció d''equips de protecció individual.', 'safety', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000005', NULL, 'Declaració de confidencialitat', 'Acord de confidencialitat i no-divulgació.', 'legal', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000006', NULL, 'Sol·licitud d''avançament salarial', 'Petició d''avançament sobre nòmina futura.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000007', NULL, 'Butlletí d''acollida', 'Document informatiu per a nous treballadors (generar i lliurar).', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'Annexe revisió salarial anual', 'Comunicació formal de revisió de salari.', 'hr', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-000000000001', 'Cessió temporal d''equipament', 'Acta de cessió d''eines o dispositius.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000010', '10000000-0000-0000-0000-000000000001', 'Autorització accés a instal·lació', 'Autorització per treballar a instal·lacions de client.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000011', '10000000-0000-0000-0000-000000000001', 'Informe d''incident tècnic', 'Registre intern d''incidents (generar i arxivar).', 'safety', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000012', '10000000-0000-0000-0000-000000000001', 'Acta de traspàs de funcions', 'Formalitza el traspàs de funcions entre dos treballadors.', 'hr', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000013', '10000000-0000-0000-0000-000000000001', 'Nota informativa RGPD', 'Informació al treballador sobre tractament de dades.', 'legal', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-000000000001', 'Informe de seguiment setmanal', 'Resum d''activitats setmanals per a direcció.', 'operations', 'docx', false, true, '20000000-0000-0000-0000-000000000002'),
  ('72000000-0000-0000-0000-000000000015', NULL, 'Test de firmes', 'Document de referència per a proves de signatura (DocuSeal i firma pròpia).', 'signing', 'docx', true, true, '20000000-0000-0000-0000-000000000001')
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
  '73000000-0000-0000-0000-000000000008', '72000000-0000-0000-0000-000000000008', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/08-revisio-salarial-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"salari_actual":{"type":"number","label":"Salari actual (EUR/any)","required":true,"order":1},"nou_salari":{"type":"number","label":"Nou salari (EUR/any)","required":true,"order":2},"percentatge":{"type":"number","label":"Increment (%)","required":true,"order":3},"data_efecte":{"type":"date","label":"Data d''efecte","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"manager":{"entity_type":"employee","label":"Director/a","order":1,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","salari_actual":"28000","nou_salari":"29400","percentatge":"5","data_efecte":"2026-01-01"}',
  true
),
(
  '73000000-0000-0000-0000-000000000009', '72000000-0000-0000-0000-000000000009', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/09-cessio-equipament-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_equip":{"type":"string","label":"Nom de l''equip","required":true,"order":1},"num_serie":{"type":"string","label":"Número de sèrie","required":false,"order":2},"data_cessio":{"type":"date","label":"Data de cessió","required":true,"order":3},"data_retorn_prevista":{"type":"date","label":"Data retorn prevista","required":true,"order":4}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"warehouse_manager":{"entity_type":"employee","label":"Responsable magatzem","order":1,"for_signing":true}}',
  '{"full_name":"Sergi Costa Ribas","nom_equip":"Tauleta de camp ruggeditzada","num_serie":"SN-2024-0042","data_cessio":"2025-07-01","data_retorn_prevista":"2025-12-31"}',
  true
),
(
  '73000000-0000-0000-0000-000000000010', '72000000-0000-0000-0000-000000000010', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/10-autoritzacio-acces-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"nom_client":{"type":"string","label":"Nom del client","required":true,"order":1},"adreca_client":{"type":"string","label":"Adreça del client","required":true,"order":2},"data_acces":{"type":"date","label":"Data d''accés","required":true,"order":3}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a","order":0,"for_signing":true},"site_manager":{"entity_type":"user","label":"Cap d''obra","order":1,"for_signing":true}}',
  '{"full_name":"Jordi Soler Mas","nom_client":"Constructora Meridian S.L.","adreca_client":"Carrer de la Indústria 45, Barcelona","data_acces":"2025-07-10"}',
  true
),
(
  '73000000-0000-0000-0000-000000000011', '72000000-0000-0000-0000-000000000011', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/11-informe-incident-tecnic-ca.docx', NULL,
  '{"data_incident":{"type":"date","label":"Data de l''incident","required":true,"order":0},"lloc":{"type":"string","label":"Lloc de l''incident","required":true,"order":1},"descripcio_incident":{"type":"string","label":"Descripció de l''incident","required":true,"order":2},"mesures_adoptades":{"type":"string","label":"Mesures adoptades","required":true,"order":3}}',
  '{}',
  '{"data_incident":"2025-06-20","lloc":"Sala quadres elèctrics, planta 2","descripcio_incident":"Curtcircuit menor. Sense ferits.","mesures_adoptades":"Substitució fusibles. Notificació al responsable."}',
  true
),
(
  '73000000-0000-0000-0000-000000000012', '72000000-0000-0000-0000-000000000012', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/12-traspas-funcions-ca.docx', NULL,
  '{"nom_cedent":{"type":"string","label":"Nom del cedent","required":true,"role":"transferor","order":0},"nom_receptor":{"type":"string","label":"Nom del receptor","required":true,"role":"recipient","order":1},"funcions_traspassades":{"type":"string","label":"Funcions traspassades","required":true,"order":2},"data_traspas":{"type":"date","label":"Data de traspàs","required":true,"order":3}}',
  '{"transferor":{"entity_type":"employee","label":"Cedent","order":0,"for_signing":true},"recipient":{"entity_type":"employee","label":"Receptor","order":1,"for_signing":true},"manager":{"entity_type":"employee","label":"Responsable RRHH","order":2,"for_signing":true}}',
  '{"nom_cedent":"Susanna Ribas Carreras","nom_receptor":"Júlia Montalba Safont","funcions_traspassades":"Coordinació equip Gràcia, gestió comandes i control magatzem","data_traspas":"2025-09-15"}',
  true
),
(
  '73000000-0000-0000-0000-000000000013', '72000000-0000-0000-0000-000000000013', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/13-nota-rgpd-ca.docx', NULL,
  '{"full_name":{"type":"string","label":"Nom del treballador/a","required":true,"role":"worker","order":0},"data":{"type":"date","label":"Data","required":true,"order":1}}',
  '{"worker":{"entity_type":"employee","label":"Treballador/a (confirmació recepció)","order":0,"for_signing":true}}',
  '{"full_name":"Marta Rovira Figueras","data":"2025-07-01"}',
  true
),
(
  '73000000-0000-0000-0000-000000000014', '72000000-0000-0000-0000-000000000014', 'ca',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '10000000-0000-0000-0000-000000000001/docx/14-informe-seguiment-setmanal-ca.docx', NULL,
  '{"setmana":{"type":"string","label":"Setmana (ex: 2025-W28)","required":true,"order":0},"responsable":{"type":"string","label":"Responsable","required":true,"order":1},"activitats":{"type":"string","label":"Activitats realitzades","required":true,"order":2},"observacions":{"type":"string","label":"Observacions","required":false,"order":3}}',
  '{}',
  '{"setmana":"2025-W28","responsable":"Marta Rovira Figueras","activitats":"Revisió quadres elèctrics edifici A i B. Manteniment preventiu equips.","observacions":"Pendent reposició peces quadre B."}',
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