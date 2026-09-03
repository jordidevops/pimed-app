-- =============================================================================
-- 08 — Plantilles tenant QSR (uniformes, formació, checklists, protocol)
-- =============================================================================

INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, created_by, target_archetypes
)
VALUES
  ('a7000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   'Protocol de registre horari BurgerVista', 'Protocol intern de fitxatge per locals BurgerVista.',
   'attendance', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001',
   'Entrega d''uniforme', 'Document d''entrega d''uniforme i material al personal.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001',
   'Retorn d''uniforme', 'Document de retorn d''uniforme en baixa o canvi.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001',
   'Formació higiene i al·lèrgens', 'Certificat de formació obligatòria d''higiene alimentària.',
   'safety', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001',
   'Checklist d''obertura de local', 'Tasques d''obertura (cuina, mostrador, apps).',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001',
   'Checklist de tancament de local', 'Tasques de tancament i neteja.',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001',
   'Checklist expedició / tancament apps', 'Tancament de torn d''expedició (sense integrar Glovo).',
   'operations', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality']),
  ('a7000000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001',
   'Acollida nou empleat BurgerVista', 'Butlletí d''acollida primer dia.',
   'hr', 'html', false, true, 'a2000000-0000-0000-0000-000000000001', ARRAY['hospitality'])
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, storage_path, html_content,
  variables_schema, signing_roles_schema, sample_values, is_active
)
VALUES
  ('a7100000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-000000000001', 'ca', 'text/html', NULL,
   '<h1>Protocol de registre horari — BurgerVista</h1><p>Empleat/da: {{full_name}}</p><p>Local: {{site_name}}</p><p>Cal fitxar entrada, pauses i sortida a l''estació del local o portal autoritzat.</p>',
   '{"full_name":{"type":"string"},"site_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"}}'::jsonb,
   '{"full_name":"Laura Roca","site_name":"BurgerVista Eixample"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000002', 'ca', 'text/html', NULL,
   '<h1>Entrega d''uniforme</h1><p>Jo, {{full_name}}, confirmo la recepció de: {{items}}.</p><p>Data: {{date}}</p>',
   '{"full_name":{"type":"string"},"items":{"type":"string"},"date":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"},"manager":{"label":"Responsable"}}'::jsonb,
   '{"full_name":"Irene Gómez","items":"2 polos, 1 davantal, 1 gorra","date":"2026-01-20"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003', 'ca', 'text/html', NULL,
   '<h1>Retorn d''uniforme</h1><p>{{full_name}} retorna: {{items}}.</p><p>Estat: {{condition}}</p>',
   '{"full_name":{"type":"string"},"items":{"type":"string"},"condition":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"},"manager":{"label":"Responsable"}}'::jsonb,
   '{"full_name":"Exemple","items":"1 polo","condition":"Bo"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000004', 'a7000000-0000-0000-0000-000000000004', 'ca', 'text/html', NULL,
   '<h1>Formació higiene i al·lèrgens</h1><p>{{full_name}} ha completat la formació el {{date}}.</p><ul><li>Higiene de mans</li><li>Temperatures</li><li>Al·lèrgens</li></ul>',
   '{"full_name":{"type":"string"},"date":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Treballador/a"}}'::jsonb,
   '{"full_name":"Marc Vidal","date":"2026-01-15"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000005', 'a7000000-0000-0000-0000-000000000005', 'ca', 'text/html', NULL,
   '<h1>Checklist d''obertura</h1><p>Local: {{site_name}} — Cap de torn: {{full_name}}</p><ol><li>Encesa equips cuina</li><li>Revisió neveres</li><li>Caixa / TPV</li><li>Apps delivery en línia (Partner)</li><li>Zona expedició preparada</li></ol>',
   '{"site_name":{"type":"string"},"full_name":{"type":"string"}}'::jsonb,
   '{"manager":{"label":"Cap de torn"}}'::jsonb,
   '{"site_name":"BurgerVista Eixample","full_name":"Pau Soler"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000006', 'a7000000-0000-0000-0000-000000000006', 'ca', 'text/html', NULL,
   '<h1>Checklist de tancament</h1><p>Local: {{site_name}} — {{full_name}}</p><ol><li>Neteja cuina</li><li>Tancament caixa</li><li>Residus</li><li>Alarmes</li></ol>',
   '{"site_name":{"type":"string"},"full_name":{"type":"string"}}'::jsonb,
   '{"manager":{"label":"Cap de torn"}}'::jsonb,
   '{"site_name":"BurgerVista Diagonal","full_name":"Joan Navarro"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000007', 'a7000000-0000-0000-0000-000000000007', 'ca', 'text/html', NULL,
   '<h1>Checklist expedició / apps</h1><p>{{full_name}} — {{site_name}}</p><p>Nota: PiMed no gestiona comandes Glovo; això és només checklist laboral.</p><ol><li>Bosses i material</li><li>Temps d''espera riders</li><li>Tancament pantalles Partner</li></ol>',
   '{"full_name":{"type":"string"},"site_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Expedició"}}'::jsonb,
   '{"full_name":"Irene Gómez","site_name":"BurgerVista Eixample"}'::jsonb, true),
  ('a7100000-0000-0000-0000-000000000008', 'a7000000-0000-0000-0000-000000000008', 'ca', 'text/html', NULL,
   '<h1>Benvinguda a BurgerVista</h1><p>Hola {{full_name}},</p><p>Benvingut/da a l''equip. Recorda: uniforme, higiene, fitxatge i zones (cuina / mostrador / expedició).</p>',
   '{"full_name":{"type":"string"}}'::jsonb,
   '{"worker":{"label":"Nou empleat"}}'::jsonb,
   '{"full_name":"Alex Muñoz"}'::jsonb, true)
ON CONFLICT (id) DO NOTHING;
