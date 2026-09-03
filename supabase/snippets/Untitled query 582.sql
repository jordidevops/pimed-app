-- =============================================================================
-- TEST: verificació del fix H2 — "unread_mention" alert
--
-- Escenari:
--   · Tenant  : Acme Corp (10000000-...0001)
--   · Entitat : Charlie (empleat 40000000-...0002)
--   · Autor   : Alice Owner (20000000-...0002)  ← escriu el comentari
--   · Mencionat: Dave Member (20000000-...0005) ← ha de veure l'alerta
--
-- Lògica esperada:
--   · Dave inicia sessió i obre la fitxa de Charlie.
--   · api.get_entity_risk_alerts('employee', '40000000-...0002')
--     ha de retornar 1 alerta kind='unread_mention'
--     on mention_name = 'Alice Owner' (qui l'ha mencionat).
-- =============================================================================

-- 1. Insereix el comentari de test (idempotent gràcies a ON CONFLICT)
INSERT INTO data.entity_comments (
  id,
  tenant_id,
  entity_type,
  entity_id,
  user_id,        -- Alice: l'autora que menciona a Dave
  content,
  mentions,
  mentions_read,  -- buit → Dave no ha llegit la menció
  parent_id,
  created_at
)
VALUES (
  'ffffffff-0000-0000-0000-000000000001',           -- id fix per poder esborrar-lo
  '10000000-0000-0000-0000-000000000001',           -- Acme Corp
  'employee',
  '40000000-0000-0000-0000-000000000002',           -- fitxa de Charlie
  '20000000-0000-0000-0000-000000000002',           -- Alice (autora)
  'He revisat el cas de @Dave — cal fer un seguiment.',
  ARRAY['20000000-0000-0000-0000-000000000005'::uuid], -- Dave (mencionat)
  '{}'::jsonb,                                      -- cap menció llegida
  NULL,
  now() - INTERVAL '72 hours'                       -- 72h > threshold 48h
)
ON CONFLICT (id) DO NOTHING;

-- 2. Confirma que el comentari existeix amb les dades correctes
SELECT
  id,
  left(content, 60)                 AS content,
  user_id                           AS autor,
  mentions[1]                       AS mencionat,
  mentions_read,
  round(extract(epoch FROM (now() - created_at)) / 3600)::int
                                    AS "hores_antiguitat"
FROM data.entity_comments
WHERE id = 'ffffffff-0000-0000-0000-000000000001';

-- 3. Simula la crida a la funció corregida en el context de Dave (mencionat)
--    Estableix el JWT de Dave a nivell de sessió i crida get_entity_risk_alerts.
SELECT set_config(
  'request.jwt.claim.sub',
  '20000000-0000-0000-0000-000000000005',   -- Dave
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub',           '20000000-0000-0000-0000-000000000005',
    'app_metadata',  jsonb_build_object(
      'user_tenants', jsonb_build_object(
        '10000000-0000-0000-0000-000000000001',
        jsonb_build_object('global_role','member','is_active',true)
      )
    )
  )::text,
  true
);

-- Resultat esperat: 1 alerta kind='unread_mention', mention_name='Alice Owner'
SELECT api.get_entity_risk_alerts(
  'employee',
  '40000000-0000-0000-0000-000000000002'  -- fitxa de Charlie
) AS alertes_dave;

-- 4. (Opcional) Neteja del comentari de test
-- DELETE FROM data.entity_comments WHERE id = 'ffffffff-0000-0000-0000-000000000001';