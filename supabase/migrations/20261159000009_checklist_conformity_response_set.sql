-- Platform response set: ISO-style conformity (Conforme / No conforme)
INSERT INTO data.checklist_response_sets (id, tenant_id, name, code, locale, category, vertical)
VALUES
  ('a1000000-0000-4000-8000-000000000004', NULL, 'Conforme / No conforme', 'conformity', 'ca', 'general', 'generic')
ON CONFLICT DO NOTHING;

INSERT INTO data.checklist_response_options (
  id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token
)
VALUES
  ('a1100000-0000-4000-8000-000000000031', 'a1000000-0000-4000-8000-000000000004',
   'Conforme', 'pass', 0, false, false, 'green'),
  ('a1100000-0000-4000-8000-000000000032', 'a1000000-0000-4000-8000-000000000004',
   'No conforme', 'fail', 1, true, true, 'red')
ON CONFLICT DO NOTHING;
