-- Platform DMS "Pressupost d'obra/reparació" (022/027 HTML+DOCX) must not remain as active platform templates.
DO $$
DECLARE
  v_left int;
  v_clones int;
BEGIN
  SELECT count(*) INTO v_left
  FROM data.document_templates
  WHERE id IN (
    '70000000-0000-0000-0000-000000000022',
    '70000000-0000-0000-0000-000000000027',
    '72000000-0000-0000-0000-000000000022',
    '72000000-0000-0000-0000-000000000027'
  )
    AND tenant_id IS NULL
    AND is_platform_default
    AND is_active;

  IF v_left <> 0 THEN
    RAISE EXCEPTION 'retired DMS quote lookalikes still active as platform templates: %', v_left;
  END IF;

  SELECT count(*) INTO v_left
  FROM data.document_templates
  WHERE id IN (
    '70000000-0000-0000-0000-000000000022',
    '70000000-0000-0000-0000-000000000027',
    '72000000-0000-0000-0000-000000000022',
    '72000000-0000-0000-0000-000000000027'
  );

  IF v_left <> 0 THEN
    RAISE EXCEPTION 'retired DMS quote lookalikes still exist: %', v_left;
  END IF;

  SELECT count(*) INTO v_clones
  FROM data.document_templates
  WHERE tenant_id IS NOT NULL
    AND cloned_from_id IN (
      '70000000-0000-0000-0000-000000000022',
      '70000000-0000-0000-0000-000000000027',
      '72000000-0000-0000-0000-000000000022',
      '72000000-0000-0000-0000-000000000027'
    );

  IF v_clones <> 0 THEN
    RAISE EXCEPTION 'tenant clones still point at retired platform ids: %', v_clones;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates
    WHERE id = '70000000-0000-0000-0000-000000000024'
      AND tenant_id IS NULL
      AND is_platform_default
      AND is_active
      AND category = 'commercial'
  ) THEN
    RAISE EXCEPTION 'hospitality commercial template 024 should remain';
  END IF;
END $$;
