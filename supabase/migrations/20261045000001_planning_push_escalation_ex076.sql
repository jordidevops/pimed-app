-- =============================================================================
-- EX-07.6 — Notificacions push openings/swaps + escalat urgent
-- Reutilitza employee_portal_push_queue (VAPID). Quiet hours excepte urgències.
-- No-objectius: email/OneSignal tenant, UI preferències avançades.
-- =============================================================================

-- ─── 1. Camps d'urgència a openings ──────────────────────────────────────────

ALTER TABLE data.shift_openings
  ADD COLUMN IF NOT EXISTS is_urgent boolean NOT NULL DEFAULT false;

ALTER TABLE data.shift_openings
  ADD COLUMN IF NOT EXISTS last_escalated_at timestamptz;

COMMENT ON COLUMN data.shift_openings.is_urgent IS
  'EX-07.6: vacant urgent (p.ex. call-off); ignora quiet hours i entra a escalat.';
COMMENT ON COLUMN data.shift_openings.last_escalated_at IS
  'EX-07.6: darrer fan-out d''escalat push.';

-- Call-off ja crea openings: marcar urgents
CREATE OR REPLACE FUNCTION data.mark_opening_urgent_from_call_off()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.notes IS NOT NULL AND NEW.notes LIKE 'call_off:%' THEN
    NEW.is_urgent := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_openings_call_off_urgent ON data.shift_openings;
CREATE TRIGGER trg_shift_openings_call_off_urgent
  BEFORE INSERT OR UPDATE OF notes ON data.shift_openings
  FOR EACH ROW EXECUTE FUNCTION data.mark_opening_urgent_from_call_off();

-- ─── 2. Quiet hours + enqueue genèric ────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.planning_push_in_quiet_hours(
  p_site_id uuid,
  p_as_of   timestamptz DEFAULT clock_timestamp()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tz text;
  v_hour int;
  v_tenant uuid;
BEGIN
  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  v_tz := COALESCE(data.get_site_timezone(p_site_id, v_tenant), 'Europe/Madrid');
  v_hour := EXTRACT(HOUR FROM (p_as_of AT TIME ZONE v_tz))::int;
  -- Quiet: 22:00–06:59
  RETURN v_hour >= 22 OR v_hour < 7;
END;
$$;

REVOKE ALL ON FUNCTION data.planning_push_in_quiet_hours(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.planning_push_in_quiet_hours(uuid, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION data.enqueue_employee_portal_planning_push(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_event       text,
  p_payload     jsonb DEFAULT '{}'::jsonb,
  p_urgent      boolean DEFAULT false,
  p_site_id     uuid DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_msg_id bigint;
  v_event  text := lower(btrim(COALESCE(p_event, '')));
  v_site   uuid;
BEGIN
  IF p_employee_id IS NULL OR p_tenant_id IS NULL OR v_event = '' THEN
    RETURN NULL;
  END IF;

  IF v_event NOT IN (
    'opening_published', 'opening_urgent',
    'claim_accepted', 'claim_rejected', 'claim_expired',
    'swap_requested', 'swap_approved', 'swap_rejected'
  ) THEN
    RETURN NULL;
  END IF;

  v_site := COALESCE(p_site_id, (p_payload->>'site_id')::uuid);

  IF NOT COALESCE(p_urgent, false)
     AND v_site IS NOT NULL
     AND data.planning_push_in_quiet_hours(v_site, clock_timestamp())
  THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_push_subscriptions s
    WHERE s.employee_id = p_employee_id
      AND s.tenant_id = p_tenant_id
  ) THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT pgmq.send(
      'employee_portal_push_queue',
      jsonb_build_object(
        'task', 'planning_push',
        'tenant_id', p_tenant_id,
        'employee_id', p_employee_id,
        'event', v_event,
        'urgent', COALESCE(p_urgent, false),
        'payload', COALESCE(p_payload, '{}'::jsonb),
        'idempotency_key',
          format(
            'portal-plan-%s-%s-%s-%s',
            v_event,
            p_employee_id,
            COALESCE(p_payload->>'entity_id', 'x'),
            extract(epoch from clock_timestamp())::bigint
          )
      )
    ) INTO v_msg_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enqueue_employee_portal_planning_push failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_msg_id;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_employee_portal_planning_push(uuid, uuid, text, jsonb, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_employee_portal_planning_push(uuid, uuid, text, jsonb, boolean, uuid) TO service_role;

CREATE OR REPLACE FUNCTION data.fanout_planning_push_to_site(
  p_tenant_id uuid,
  p_site_id   uuid,
  p_event     text,
  p_payload   jsonb DEFAULT '{}'::jsonb,
  p_urgent    boolean DEFAULT false,
  p_exclude_employee_id uuid DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_count int := 0;
  v_emp uuid;
  v_msg bigint;
BEGIN
  FOR v_emp IN
    SELECT DISTINCT e.id
    FROM data.employees e
    JOIN data.employee_portal_push_subscriptions s
      ON s.employee_id = e.id AND s.tenant_id = e.tenant_id
    WHERE e.tenant_id = p_tenant_id
      AND e.site_id = p_site_id
      AND e.status = 'active'
      AND (p_exclude_employee_id IS NULL OR e.id <> p_exclude_employee_id)
  LOOP
    v_msg := data.enqueue_employee_portal_planning_push(
      p_tenant_id, v_emp, p_event,
      COALESCE(p_payload, '{}'::jsonb) || jsonb_build_object('site_id', p_site_id),
      p_urgent, p_site_id
    );
    IF v_msg IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION data.fanout_planning_push_to_site(uuid, uuid, text, jsonb, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.fanout_planning_push_to_site(uuid, uuid, text, jsonb, boolean, uuid) TO service_role;

-- ─── 3. Triggers ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.trg_shift_openings_planning_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_event text;
  v_payload jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'open' THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NOT (NEW.status = 'open' AND OLD.status IS DISTINCT FROM 'open') THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  v_event := CASE WHEN NEW.is_urgent THEN 'opening_urgent' ELSE 'opening_published' END;
  v_payload := jsonb_build_object(
    'entity_type', 'shift_opening',
    'entity_id', NEW.id,
    'site_id', NEW.site_id,
    'opening_date', NEW.opening_date,
    'start_time', to_char(NEW.start_time, 'HH24:MI'),
    'end_time', to_char(NEW.end_time, 'HH24:MI'),
    'title', NEW.title,
    'is_urgent', NEW.is_urgent
  );

  PERFORM data.fanout_planning_push_to_site(
    NEW.tenant_id, NEW.site_id, v_event, v_payload, NEW.is_urgent, NULL
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_openings_planning_push ON data.shift_openings;
CREATE TRIGGER trg_shift_openings_planning_push
  AFTER INSERT OR UPDATE OF status ON data.shift_openings
  FOR EACH ROW EXECUTE FUNCTION data.trg_shift_openings_planning_push();

CREATE OR REPLACE FUNCTION data.trg_shift_opening_claims_planning_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_opening data.shift_openings;
  v_event text;
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  v_event := CASE NEW.status
    WHEN 'accepted' THEN 'claim_accepted'
    WHEN 'rejected' THEN 'claim_rejected'
    WHEN 'expired' THEN 'claim_expired'
    ELSE NULL
  END;

  IF v_event IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = NEW.opening_id;

  PERFORM data.enqueue_employee_portal_planning_push(
    NEW.tenant_id,
    NEW.employee_id,
    v_event,
    jsonb_build_object(
      'entity_type', 'shift_opening_claim',
      'entity_id', NEW.id,
      'opening_id', NEW.opening_id,
      'site_id', v_opening.site_id,
      'opening_date', v_opening.opening_date,
      'start_time', to_char(v_opening.start_time, 'HH24:MI'),
      'end_time', to_char(v_opening.end_time, 'HH24:MI'),
      'title', v_opening.title
    ),
    COALESCE(v_opening.is_urgent, false),
    v_opening.site_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_opening_claims_planning_push ON data.shift_opening_claims;
CREATE TRIGGER trg_shift_opening_claims_planning_push
  AFTER UPDATE OF status ON data.shift_opening_claims
  FOR EACH ROW EXECUTE FUNCTION data.trg_shift_opening_claims_planning_push();

CREATE OR REPLACE FUNCTION data.trg_shift_swap_requests_planning_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_slot record;
  v_payload jsonb;
BEGIN
  SELECT ss.site_id, ss.slot_date, ss.start_time, ss.end_time, ss.tenant_id
  INTO v_slot
  FROM data.shift_slots ss
  WHERE ss.id = COALESCE(NEW.requester_slot_id, OLD.requester_slot_id);

  IF NOT FOUND THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  v_payload := jsonb_build_object(
    'entity_type', 'shift_swap_request',
    'entity_id', NEW.id,
    'kind', NEW.kind,
    'site_id', v_slot.site_id,
    'slot_date', v_slot.slot_date,
    'start_time', to_char(v_slot.start_time, 'HH24:MI'),
    'end_time', to_char(v_slot.end_time, 'HH24:MI')
  );

  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    IF NEW.target_employee_id IS NOT NULL THEN
      PERFORM data.enqueue_employee_portal_planning_push(
        NEW.tenant_id, NEW.target_employee_id, 'swap_requested',
        v_payload, NEW.kind = 'call_off', v_slot.site_id
      );
    ELSIF NEW.kind = 'give_away' THEN
      -- Cessió oberta: avisar companys del centre
      PERFORM data.fanout_planning_push_to_site(
        NEW.tenant_id, v_slot.site_id, 'swap_requested', v_payload,
        false, NEW.requester_id
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status = 'pending'
     AND NEW.status IN ('approved', 'rejected')
  THEN
    PERFORM data.enqueue_employee_portal_planning_push(
      NEW.tenant_id, NEW.requester_id,
      CASE WHEN NEW.status = 'approved' THEN 'swap_approved' ELSE 'swap_rejected' END,
      v_payload,
      NEW.kind = 'call_off',
      v_slot.site_id
    );

    IF NEW.target_employee_id IS NOT NULL AND NEW.status = 'approved' THEN
      PERFORM data.enqueue_employee_portal_planning_push(
        NEW.tenant_id, NEW.target_employee_id, 'swap_approved',
        v_payload, NEW.kind = 'call_off', v_slot.site_id
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_swap_requests_planning_push ON data.shift_swap_requests;
CREATE TRIGGER trg_shift_swap_requests_planning_push
  AFTER INSERT OR UPDATE OF status ON data.shift_swap_requests
  FOR EACH ROW EXECUTE FUNCTION data.trg_shift_swap_requests_planning_push();

-- ─── 4. Escalat urgent ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.escalate_urgent_shift_openings(
  p_as_of timestamptz DEFAULT clock_timestamp(),
  p_min_interval_hours int DEFAULT 2
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row record;
  v_notified int := 0;
  v_openings int := 0;
  v_fanout int;
  v_interval interval;
BEGIN
  v_interval := make_interval(hours => GREATEST(COALESCE(p_min_interval_hours, 2), 1));

  FOR v_row IN
    SELECT o.*
    FROM data.shift_openings o
    WHERE o.status = 'open'
      AND o.places_filled < o.places_total
      AND (
        o.is_urgent
        OR o.opening_date <= (p_as_of AT TIME ZONE 'UTC')::date
        OR (o.closes_at IS NOT NULL AND o.closes_at <= p_as_of + interval '4 hours')
      )
      AND (
        o.last_escalated_at IS NULL
        OR o.last_escalated_at <= p_as_of - v_interval
      )
    ORDER BY o.is_urgent DESC, o.opening_date ASC, o.start_time ASC
    LIMIT 50
  LOOP
    v_openings := v_openings + 1;
    v_fanout := data.fanout_planning_push_to_site(
      v_row.tenant_id,
      v_row.site_id,
      'opening_urgent',
      jsonb_build_object(
        'entity_type', 'shift_opening',
        'entity_id', v_row.id,
        'site_id', v_row.site_id,
        'opening_date', v_row.opening_date,
        'start_time', to_char(v_row.start_time, 'HH24:MI'),
        'end_time', to_char(v_row.end_time, 'HH24:MI'),
        'title', v_row.title,
        'is_urgent', true,
        'escalated', true
      ),
      true,
      NULL
    );
    v_notified := v_notified + v_fanout;

    UPDATE data.shift_openings
    SET last_escalated_at = p_as_of, updated_at = now()
    WHERE id = v_row.id;
  END LOOP;

  RETURN jsonb_build_object(
    'openings_escalated', v_openings,
    'employees_notified', v_notified,
    'as_of', p_as_of
  );
END;
$$;

REVOKE ALL ON FUNCTION api.escalate_urgent_shift_openings(timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.escalate_urgent_shift_openings(timestamptz, int) TO service_role;

COMMENT ON FUNCTION api.escalate_urgent_shift_openings IS
  'EX-07.6: re-notifica vacants obertes urgents/properes (service_role / cron).';

-- Cron cada 15 min (si pg_cron disponible)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('escalate-urgent-shift-openings')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'escalate-urgent-shift-openings'
    );

    PERFORM cron.schedule(
      'escalate-urgent-shift-openings',
      '*/15 * * * *',
      $cron$SELECT api.escalate_urgent_shift_openings(clock_timestamp(), 2)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'EX-07.6: no s''ha pogut programar cron escalate-urgent-shift-openings: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
