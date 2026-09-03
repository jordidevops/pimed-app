-- =============================================================================
-- EX-03.5 — Recompute idempotent en canvis de shift_slots publicats
--
-- Qualsevol transició rellevant d'un slot publicat encua
-- (employee_id, work_date) a attendance_recompute_queue.
-- Draft no afecta. Mai bloqueja la planificació (swallow errors).
-- =============================================================================

-- ─── Helper compartit d'enqueue ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.enqueue_attendance_day_recompute(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_work_date   date,
  p_reason      text DEFAULT 'shift_slot'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_msg_id bigint;
  v_reason text := left(COALESCE(nullif(btrim(p_reason), ''), 'shift_slot'), 64);
BEGIN
  IF p_employee_id IS NULL OR p_work_date IS NULL OR p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    SELECT pgmq.send(
      'attendance_recompute_queue',
      jsonb_build_object(
        'task', 'recompute_attendance_day',
        'tenant_id', p_tenant_id,
        'employee_id', p_employee_id,
        'work_date', p_work_date::text,
        'reason', v_reason,
        'idempotency_key',
          format(
            'recompute-%s-%s-%s',
            p_employee_id,
            p_work_date,
            v_reason
          )
      )
    ) INTO v_msg_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enqueue_attendance_day_recompute failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_msg_id;
END;
$$;

COMMENT ON FUNCTION data.enqueue_attendance_day_recompute(uuid, uuid, date, text) IS
  'EX-03.5: encua recomputació de dia a attendance_recompute_queue (idempotent / no bloquejant).';

REVOKE ALL ON FUNCTION data.enqueue_attendance_day_recompute(uuid, uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_attendance_day_recompute(uuid, uuid, date, text) TO service_role;

-- ─── Trigger: canvis rellevants a slots publicats ─────────────────────────────

CREATE OR REPLACE FUNCTION data.trg_shift_slots_attendance_recompute()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'published' AND NEW.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_attendance_day_recompute(
        NEW.tenant_id, NEW.employee_id, NEW.slot_date,
        format('slot-%s-published', NEW.id)
      );
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- draft → published
    IF OLD.status IS DISTINCT FROM 'published'
       AND NEW.status = 'published'
       AND NEW.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_attendance_day_recompute(
        NEW.tenant_id, NEW.employee_id, NEW.slot_date,
        format('slot-%s-published', NEW.id)
      );
    END IF;

    -- published → cancelled
    IF OLD.status = 'published'
       AND NEW.status = 'cancelled'
       AND OLD.employee_id IS NOT NULL THEN
      PERFORM data.enqueue_attendance_day_recompute(
        OLD.tenant_id, OLD.employee_id, OLD.slot_date,
        format('slot-%s-cancelled', OLD.id)
      );
    END IF;

    -- published → published: canvis d'empleat/data/horari (si el freeze ho permet)
    IF OLD.status = 'published' AND NEW.status = 'published' THEN
      IF OLD.employee_id IS DISTINCT FROM NEW.employee_id
         OR OLD.slot_date IS DISTINCT FROM NEW.slot_date THEN
        IF OLD.employee_id IS NOT NULL AND OLD.slot_date IS NOT NULL THEN
          PERFORM data.enqueue_attendance_day_recompute(
            OLD.tenant_id, OLD.employee_id, OLD.slot_date,
            format('slot-%s-moved-from', OLD.id)
          );
        END IF;
        IF NEW.employee_id IS NOT NULL AND NEW.slot_date IS NOT NULL THEN
          PERFORM data.enqueue_attendance_day_recompute(
            NEW.tenant_id, NEW.employee_id, NEW.slot_date,
            format('slot-%s-moved-to', NEW.id)
          );
        END IF;
      ELSIF NEW.employee_id IS NOT NULL
        AND (
          OLD.shift_id IS DISTINCT FROM NEW.shift_id
          OR OLD.start_time IS DISTINCT FROM NEW.start_time
          OR OLD.end_time IS DISTINCT FROM NEW.end_time
          OR OLD.location_id IS DISTINCT FROM NEW.location_id
        ) THEN
        PERFORM data.enqueue_attendance_day_recompute(
          NEW.tenant_id, NEW.employee_id, NEW.slot_date,
          format('slot-%s-changed', NEW.id)
        );
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shift_slots_attendance_recompute ON data.shift_slots;

CREATE TRIGGER trg_shift_slots_attendance_recompute
  AFTER INSERT OR UPDATE ON data.shift_slots
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_shift_slots_attendance_recompute();

COMMENT ON FUNCTION data.trg_shift_slots_attendance_recompute() IS
  'EX-03.5: AFTER trigger — encua recompute quan un slot publicat canvia; draft ignorat.';
