-- =============================================================================
-- Entity Timeline — Fix H2: api.get_entity_risk_alerts unread_mention filter
--
-- Bug: el filtre `ec.user_id = v_user_id` retornava comentaris ESCRITS per
--   l'usuari actual (autor) en comptes dels comentaris ON l'usuari és MENCIONAT.
-- Fix: canviar a `m = v_user_id` i fer el join de perfil sobre l'autor del
--   comentari (ec.user_id) per exposar el nom de qui ha fet la menció.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_entity_risk_alerts(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_rule      data.entity_risk_rules%ROWTYPE;
  v_alerts    jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rule
  FROM data.entity_risk_rules
  WHERE tenant_id = v_tenant_id
    AND rule_type = 'unread_mention'
    AND is_active = true;

  IF FOUND THEN
    v_alerts := v_alerts || coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'kind',            'unread_mention',
        'comment_id',      ec.id,
        'mention_id',      m,
        'mention_name',    coalesce(pr.full_name, '?'),
        'created_at',      ec.created_at,
        'content_preview', left(ec.content, 120)
      ))
      FROM data.entity_comments ec
      CROSS JOIN LATERAL unnest(coalesce(ec.mentions, ARRAY[]::uuid[])) AS m
      LEFT JOIN data.profiles pr ON pr.id = ec.user_id
      WHERE ec.tenant_id = v_tenant_id
        AND ec.entity_type = p_entity_type
        AND ec.entity_id = p_entity_id
        AND m = v_user_id
        AND ec.parent_id IS NULL
        AND ec.deleted_at IS NULL
        AND ec.created_at < now() - data.risk_rule_threshold_interval(
          v_rule.threshold_value, v_rule.threshold_unit
        )
        AND data.mention_is_unread(ec.mentions_read, m)
    ), '[]'::jsonb);
  END IF;

  v_alerts := v_alerts || coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'kind',         'status_churn',
      'incident_id',  i.id,
      'detected_at',  i.detected_at,
      'change_count', i.context -> 'change_count',
      'message',      'Alta rotació interna — '
        || coalesce(i.context ->> 'change_count', '?')
        || ' canvis d''estat en 30 dies'
    ))
    FROM data.entity_risk_incidents i
    WHERE i.tenant_id = v_tenant_id
      AND i.entity_type = p_entity_type
      AND i.entity_id = p_entity_id
      AND i.rule_type = 'employee_status_churn'
      AND i.status = 'acted'
      AND i.detected_at >= now() - interval '7 days'
  ), '[]'::jsonb);

  RETURN v_alerts;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_entity_risk_alerts(text, uuid) TO authenticated;
