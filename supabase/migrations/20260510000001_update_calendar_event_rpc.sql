-- =============================================================================
-- Migration: 20260510000001_update_calendar_event_rpc.sql
-- Propòsit : RPC per actualitzar events de calendari manuals des del frontend.
--            Segueix el patró SECURITY INVOKER + RLS de la taula data.calendar_events.
--
-- Conté:
--   1. api.update_calendar_event(p_id, p_title, p_description, p_start_at, p_end_at, p_all_day)
--
-- Restriccions de seguretat:
--   - Només pot actualitzar events de tipus 'manual' (els creats per l'usuari).
--   - L'usuari ha de ser l'owner_id de l'event O tenir permís 'calendar.edit' al tenant/site.
--   - La RLS de data.calendar_events (UPDATE) es verifica automàticament pel SECURITY INVOKER.
-- =============================================================================

-- =============================================================================
-- 1. RPC: api.update_calendar_event
-- =============================================================================
CREATE OR REPLACE FUNCTION api.update_calendar_event(
  p_id          uuid,
  p_title       text,
  p_description text DEFAULT NULL,
  p_start_at    timestamptz DEFAULT NULL,
  p_end_at      timestamptz DEFAULT NULL,
  p_all_day     boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_owner_id  uuid;
  v_tenant_id uuid;
  v_site_id   uuid;
  v_entity_type text;
BEGIN
  -- Validate input
  IF p_title IS NULL OR trim(p_title) = '' THEN
    RAISE EXCEPTION 'title_required' USING ERRCODE = 'check_violation';
  END IF;

  IF length(p_title) > 255 THEN
    RAISE EXCEPTION 'title_too_long' USING ERRCODE = 'check_violation';
  END IF;

  IF p_start_at IS NULL THEN
    RAISE EXCEPTION 'start_at_required' USING ERRCODE = 'check_violation';
  END IF;

  IF p_end_at IS NOT NULL AND p_end_at < p_start_at THEN
    RAISE EXCEPTION 'end_before_start' USING ERRCODE = 'check_violation';
  END IF;

  -- Fetch event metadata
  SELECT owner_id, tenant_id, site_id, entity_type
    INTO v_owner_id, v_tenant_id, v_site_id, v_entity_type
    FROM data.calendar_events
   WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found' USING ERRCODE = 'not_found';
  END IF;

  -- Only manual events can be edited via this RPC
  IF v_entity_type <> 'manual' THEN
    RAISE EXCEPTION 'not_manual_event' USING ERRCODE = 'check_violation';
  END IF;

  -- Authorization: must be owner OR have calendar.edit permission
  IF v_owner_id <> auth.uid() THEN
    DECLARE
      v_perms jsonb := data.jwt_user_tenants() -> v_tenant_id::text;
      v_has_perm boolean := false;
    BEGIN
      -- Check global permission
      IF (v_perms -> 'permissions') ? 'calendar.edit' THEN
        v_has_perm := true;
      END IF;

      -- Check site-level permission if event belongs to a site
      IF NOT v_has_perm AND v_site_id IS NOT NULL THEN
        IF (v_perms -> 'sites' -> v_site_id::text -> 'permissions') ? 'calendar.edit' THEN
          v_has_perm := true;
        END IF;
      END IF;

      IF NOT v_has_perm THEN
        RAISE EXCEPTION 'permission_denied' USING ERRCODE = 'insufficient_privilege';
      END IF;
    END;
  END IF;

  -- Perform update
  UPDATE data.calendar_events
     SET title       = p_title,
         description = p_description,
         start_at    = p_start_at,
         end_at      = p_end_at,
         all_day     = p_all_day,
         updated_at  = now()
   WHERE id = p_id;

  -- Audit log (fire-and-forget pattern)
  BEGIN
    PERFORM data.log_audit_event(
      'CALENDAR_EVENT_UPDATED',
      'calendar_event',
      p_id,
      jsonb_build_object(
        'title', p_title,
        'tenant_id', v_tenant_id
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- Non-critical: do not break the update
    NULL;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_calendar_event(uuid, text, text, timestamptz, timestamptz, boolean)
  TO authenticated;

COMMENT ON FUNCTION api.update_calendar_event IS
  'Actualitza un event de calendari de tipus manual. Valida ownership o permís calendar.edit.';
