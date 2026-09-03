
-- ─── Plantilles de documents DOCX ─────────────────────────────────────────
-- Prefix 72: document_templates  (001-028, template_type='docx')
-- Prefix 73: document_template_locales (001-028, locale='ca', mime=docx)
-- Generat amb: cd scripts && node generate-docx-seed.mjs

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
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
  ('72000000-0000-0000-0000-000000000015', NULL, 'Test de firmes', 'Document de referència per a proves de signatura (DocuSeal i firma pròpia).', 'signing', 'docx', true, true, '20000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000016', NULL, 'Carta d''advertència laboral', 'Comunicació formal d''advertència o amonestació a l''empleat/da.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['generic','practice','hospitality','workshop_maker']),
  ('72000000-0000-0000-0000-000000000017', NULL, 'Acord de teletreball', 'Acord individual de treball a distància.', 'hr', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['generic','practice']),
  ('72000000-0000-0000-0000-000000000018', NULL, 'Consentiment informat', 'Full de consentiment informat per a actes o tractaments.', 'legal', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000019', NULL, 'Full d''admissió de pacient/client', 'Obertura d''expedient amb dades del pacient o client.', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000020', NULL, 'Informe de visita o sessió', 'Registre intern de visita professional (sense signatura).', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['practice']),
  ('72000000-0000-0000-0000-000000000021', NULL, 'Full d''intervenció tècnica', 'Acta d''intervenció a domicili o instal·lació del client.', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['field_service']),
  ('72000000-0000-0000-0000-000000000022', NULL, 'Pressupost d''obra o instal·lació', 'Oferta econòmica per a client amb acceptació per signatura.', 'commercial', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['field_service','workshop_maker']),
  ('72000000-0000-0000-0000-000000000023', NULL, 'Certificat de finalització de treballs', 'Certificació de treballs completats amb signatura del client.', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['field_service']),
  ('72000000-0000-0000-0000-000000000024', NULL, 'Contracte de reserva d''esdeveniment', 'Reserva de sala o esdeveniment privat amb signatura del client.', 'commercial', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('72000000-0000-0000-0000-000000000025', NULL, 'Full de comanda de càtering', 'Comanda interna de càtering (sense signatura).', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('72000000-0000-0000-0000-000000000026', NULL, 'Ordre de reparació', 'Recepció d''equipament o vehicle amb signatura del client.', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['workshop_maker']),
  ('72000000-0000-0000-0000-000000000027', NULL, 'Pressupost de reparació', 'Pressupost amb acceptació del client.', 'commercial', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['workshop_maker']),
  ('72000000-0000-0000-0000-000000000028', NULL, 'Certificat de lliurament', 'Lliurament d''equip reparat amb signatura del client.', 'operations', 'docx', true, true, '20000000-0000-0000-0000-000000000001', ARRAY['workshop_maker'])
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
),
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