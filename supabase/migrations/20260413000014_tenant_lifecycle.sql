-- =============================================================================
-- Migració 14: Tenant Lifecycle — User Quotas & Health Checks
-- =============================================================================
-- Afegeix:
--   • data.check_tenant_health(uuid)  — retorna diagnòstic de salut d'un tenant
--   • data.enforce_member_quota()     — trigger: bloqueja INSERTs quan el pla
--                                       no té places disponibles
--   • data.protect_last_owner()       — trigger: evita deixar un tenant sense owner
--
-- NOTA: El límit de places ("seat limit") s'implementa sobre la columna existent
--       data.plans.max_members. No afegim max_users per evitar duplicitat.
--       La funció exposa la columna com "max_users" per alineació semàntica.
-- =============================================================================


-- =============================================================================
-- 1. data.check_tenant_health
-- Retorna un diagnòstic complet de l'estat d'un tenant.
-- Usada per al Admin Portal i potencialment per cron jobs de monitoring.
-- SECURITY DEFINER per llegir tenant_members i plans sense interferència RLS.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.check_tenant_health(p_tenant_id uuid)
RETURNS TABLE (
  has_active_owner  boolean,
  active_members    integer,
  max_users         integer,
  is_over_quota     boolean
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = data AS $$
  SELECT
    -- Té almenys un membre actiu amb rol 'owner'
    EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id
         AND role      = 'owner'
         AND is_active = true
    ) AS has_active_owner,

    -- Membres actius totals
    (
      SELECT COUNT(*)::integer
        FROM data.tenant_members
       WHERE tenant_id = p_tenant_id
         AND is_active = true
    ) AS active_members,

    -- Límit de places del pla (max_members)
    COALESCE(
      (SELECT p.max_members
         FROM data.tenants t
         JOIN data.plans p ON p.id = t.plan_id
        WHERE t.id = p_tenant_id),
      0
    ) AS max_users,

    -- Quota superada: actius > límit del pla (0 = sense límit)
    (
      (
        SELECT COUNT(*)::integer
          FROM data.tenant_members
         WHERE tenant_id = p_tenant_id
           AND is_active = true
      ) >
      COALESCE(
        (SELECT p.max_members
           FROM data.tenants t
           JOIN data.plans p ON p.id = t.plan_id
          WHERE t.id = p_tenant_id),
        0
      )
      AND
      COALESCE(
        (SELECT p.max_members
           FROM data.tenants t
           JOIN data.plans p ON p.id = t.plan_id
          WHERE t.id = p_tenant_id),
        0
      ) > 0
    ) AS is_over_quota
$$;

GRANT EXECUTE ON FUNCTION data.check_tenant_health(uuid) TO service_role;


-- =============================================================================
-- 2. data.enforce_member_quota
-- Trigger BEFORE INSERT/UPDATE a data.tenant_members.
-- Impedeix afegir membres nous (is_active = true) si el pla ja està al límit.
-- El rol prisma_admin té BYPASSRLS i omete el trigger gràcies al check de rol.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.enforce_member_quota()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_limit   integer;
  v_current integer;
BEGIN
  -- Salta si estem desactivant un membre (no afegim places)
  IF NEW.is_active = false THEN
    RETURN NEW;
  END IF;

  -- Salta si la fila ja existia i el canvi no activa un membre prèviament inactiu
  IF TG_OP = 'UPDATE' AND OLD.is_active = true THEN
    RETURN NEW;
  END IF;

  -- Obtenir el límit de places del pla del tenant
  SELECT p.max_members
    INTO v_limit
    FROM data.tenants t
    JOIN data.plans   p ON p.id = t.plan_id
   WHERE t.id = NEW.tenant_id;

  -- Sense pla o límit 0 = sense restricció
  IF v_limit IS NULL OR v_limit = 0 THEN
    RETURN NEW;
  END IF;

  -- Comptar membres actius actuals (sense comptar la fila nova)
  SELECT COUNT(*)::integer
    INTO v_current
    FROM data.tenant_members
   WHERE tenant_id = NEW.tenant_id
     AND is_active = true
     AND (TG_OP = 'INSERT' OR id != NEW.id);

  IF v_current >= v_limit THEN
    RAISE EXCEPTION 'quota_exceeded: El pla d''aquest tenant només permet % usuaris actius. Actualitza el pla per afegir-ne més.',
      v_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_member_quota
  BEFORE INSERT OR UPDATE ON data.tenant_members
  FOR EACH ROW EXECUTE FUNCTION data.enforce_member_quota();


-- =============================================================================
-- 3. data.protect_last_owner
-- Trigger BEFORE UPDATE OR DELETE a data.tenant_members.
-- Evita que un tenant es quedi sense cap owner actiu.
--
-- Casos bloquejats:
--   UPDATE: canviar role != 'owner' O is_active = false si és l'últim owner actiu.
--   DELETE: eliminar l'últim owner actiu.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.protect_last_owner()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_active_owners integer;
BEGIN
  -- Només actuar sobre membres que eren owners actius
  IF OLD.role != 'owner' OR OLD.is_active = false THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Comprovar si el canvi "retira" l'owner status
  IF TG_OP = 'DELETE'
     OR (TG_OP = 'UPDATE' AND (NEW.role != 'owner' OR NEW.is_active = false))
  THEN
    SELECT COUNT(*)::integer
      INTO v_active_owners
      FROM data.tenant_members
     WHERE tenant_id  = OLD.tenant_id
       AND role       = 'owner'
       AND is_active  = true
       AND id        != OLD.id;   -- excloure la fila actual

    IF v_active_owners = 0 THEN
      RAISE EXCEPTION 'last_owner_protection: No es pot eliminar o rebaixar l''unic owner actiu del tenant. Assigna primer un altre owner.'
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_protect_last_owner
  BEFORE UPDATE OR DELETE ON data.tenant_members
  FOR EACH ROW EXECUTE FUNCTION data.protect_last_owner();
