
-- ─── Plantilles de documents DOCX ─────────────────────────────────────────
-- Prefix 72: document_templates  (001-028, template_type='docx')
-- Prefix 73: document_template_locales (001-028, locale='ca', mime=docx)
-- Generat amb: cd scripts && node generate-docx-seed.mjs

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES
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