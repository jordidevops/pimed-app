-- =============================================================================
-- Elimina NOMÉS les dades de seed (UUIDs fixes)
-- Conserva les dades reals. Ordre invers per respectar les FK constraints.
-- =============================================================================

-- Notes de prova
DELETE FROM data.notes
WHERE tenant_id IN (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002'
);

-- Membresies de prova
DELETE FROM data.tenant_members
WHERE tenant_id IN (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002'
);

-- Subscripcions de prova
DELETE FROM data.subscriptions
WHERE tenant_id IN (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002'
);

-- Tenants de prova
DELETE FROM data.tenants
WHERE id IN (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002'
);

-- Profiles de prova
DELETE FROM data.profiles
WHERE id LIKE '20000000-0000-0000-0000-0000000000%';

-- Identities de prova (necessari abans d'esborrar auth.users)
DELETE FROM auth.identities
WHERE user_id LIKE '20000000-0000-0000-0000-0000000000%';

-- Usuaris de prova
-- Alternativa: Supabase Dashboard → Authentication → Users → esborrar manualment
DELETE FROM auth.users
WHERE id LIKE '20000000-0000-0000-0000-0000000000%';

-- Plans de prova
DELETE FROM data.plans
WHERE id LIKE '00000000-0000-0000-0000-0000000000%';
