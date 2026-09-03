-- =============================================================================
-- Migration: 20260508000001_calendar_global_site_visibility.sql
-- Propòsit : Corregir la visibilitat dels calendar_events globals (site_id NULL)
--            perquè qualsevol membre del tenant amb el permís requerit en algun
--            context del tenant els pugui veure, no només els usuaris amb rol
--            global o owner_id.
--
-- Cas corregit:
--   · Usuari site-only (viewer/member/manager) d'un tenant
--   · Event global del tenant amb required_permissions = ARRAY['calendar.view']
--   · Abans: NO visible si l'usuari no tenia global_permissions
--   · Ara: visible si té el permís requerit en qualsevol site del tenant
-- =============================================================================

CREATE OR REPLACE FUNCTION data.jwt_can_see_calendar_event(
  p_tenant_id          uuid,
  p_required_perms     text[],
  p_site_id            uuid,
  p_owner_id           uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  WITH perms AS (
    SELECT
      COALESCE(
        data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions',
        '[]'::jsonb
      ) AS global_perms,
      COALESCE(
        data.jwt_user_permissions() -> p_tenant_id::text -> 'sites',
        '{}'::jsonb
      ) AS site_perms
  )
  SELECT
    p_owner_id = auth.uid()
    OR cardinality(p_required_perms) = 0
    OR (
      cardinality(p_required_perms) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM unnest(p_required_perms) AS req_perm
        CROSS JOIN perms
        WHERE NOT (
          perms.global_perms @> '["*"]'::jsonb
          OR perms.global_perms ? req_perm
          OR (
            p_site_id IS NOT NULL
            AND (
              (perms.site_perms -> p_site_id::text -> 'permissions') @> '["*"]'::jsonb
              OR (perms.site_perms -> p_site_id::text -> 'permissions') ? req_perm
            )
          )
          OR (
            p_site_id IS NULL
            AND EXISTS (
              SELECT 1
              FROM jsonb_each(perms.site_perms) AS site_perm(site_id, payload)
              WHERE (payload -> 'permissions') @> '["*"]'::jsonb
                 OR (payload -> 'permissions') ? req_perm
            )
          )
        )
      )
    );
$$;

GRANT EXECUTE ON FUNCTION data.jwt_can_see_calendar_event(uuid, text[], uuid, uuid)
  TO authenticated;