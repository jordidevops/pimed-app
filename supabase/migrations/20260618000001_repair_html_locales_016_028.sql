-- Reparació: locales HTML 016-028 (plantilles noves per arquetip)
-- La migració 20260617000001 es va aplicar abans d'incloure aquests INSERTs;
-- editar una migració ja aplicada no la torna a executar. Aquesta migració és idempotent.

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
