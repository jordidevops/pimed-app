-- RPC per llistar tots els entitlements de vacances del tenant (tots els anys configurats).
-- Inclou els dies usats (absències aprovades) per any.

CREATE OR REPLACE FUNCTION api.list_tenant_vacation_entitlements(
  p_leave_type text DEFAULT 'vacation'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  RETURN (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',             ve.id,
          'year',           ve.year,
          'scope',          ve.scope,
          'leave_type',     ve.leave_type,
          'days_allocated', ve.days_allocated,
          'days_used',      COALESCE(ve.days_used, 0),
          'days_remaining', GREATEST(0, ve.days_allocated - COALESCE(ve.days_used, 0))
        )
        ORDER BY ve.year DESC, CASE ve.scope WHEN 'employee' THEN 1 WHEN 'department' THEN 2 ELSE 3 END
      ),
      '[]'::jsonb
    )
    FROM data.vacation_entitlements ve
    WHERE ve.tenant_id = v_tenant_id
      AND ve.leave_type = p_leave_type
      AND ve.scope = 'tenant'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_tenant_vacation_entitlements TO authenticated;
