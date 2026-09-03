-- M4: suport PDF al xat — límits MIME/size al registre de capacitats

ALTER TABLE data.ai_model_capabilities
  ADD COLUMN IF NOT EXISTS supported_file_mimes text[] NOT NULL DEFAULT ARRAY['application/pdf'],
  ADD COLUMN IF NOT EXISTS max_file_size_mb integer NOT NULL DEFAULT 10;

ALTER TABLE data.ai_model_capabilities
  DROP CONSTRAINT IF EXISTS ai_model_capabilities_max_file_size_mb_check;
ALTER TABLE data.ai_model_capabilities
  ADD CONSTRAINT ai_model_capabilities_max_file_size_mb_check
  CHECK (max_file_size_mb >= 1 AND max_file_size_mb <= 50);

COMMENT ON COLUMN data.ai_model_capabilities.supported_file_mimes IS
  'MIME types de fitxers adjunts al xat (p.ex. application/pdf).';
COMMENT ON COLUMN data.ai_model_capabilities.max_file_size_mb IS
  'Mida màxima per fitxer adjunt (PDF) en MB.';

UPDATE data.ai_model_capabilities
SET
  supported_file_mimes = ARRAY['application/pdf'],
  max_file_size_mb = 10,
  updated_at = now()
WHERE supported_file_mimes IS NULL OR max_file_size_mb IS NULL;

-- ---------------------------------------------------------------------------
-- get_ai_model_capabilities — inclou PDF
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_model_capabilities(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id = auth.uid()
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Access denied: not a tenant member';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_data ORDER BY provider, model_id)
    FROM (
      SELECT jsonb_build_object(
        'provider', c.provider,
        'model_id', c.model_id,
        'vision', c.vision,
        'tools', c.tools,
        'tools_with_vision', c.tools_with_vision,
        'streaming', c.streaming,
        'max_image_size_mb', c.max_image_size_mb,
        'supported_image_mimes', c.supported_image_mimes,
        'max_file_size_mb', c.max_file_size_mb,
        'supported_file_mimes', c.supported_file_mimes,
        'context_window', c.context_window,
        'deprecated_at', c.deprecated_at,
        'needs_review', c.needs_review
      ) AS row_data,
      c.provider,
      c.model_id
      FROM data.ai_model_capabilities c
      WHERE c.deprecated_at IS NULL
    ) sub
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_ai_model_capabilities(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- resolve_ai_model_capabilities_service — inclou PDF
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resolve_ai_model_capabilities_service(
  p_tenant_id uuid,
  p_provider  data.ai_provider,
  p_model_id  text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   data.ai_model_capabilities%ROWTYPE;
  v_model text := nullif(trim(p_model_id), '');
  v_inner text;
  v_map   data.ai_provider;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_model IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM data.ai_model_capabilities c
  WHERE c.provider = p_provider
    AND c.model_id = v_model
    AND c.deprecated_at IS NULL;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'provider', v_row.provider,
      'model_id', v_row.model_id,
      'vision', v_row.vision,
      'tools', v_row.tools,
      'tools_with_vision', v_row.tools_with_vision,
      'streaming', v_row.streaming,
      'max_image_size_mb', v_row.max_image_size_mb,
      'supported_image_mimes', v_row.supported_image_mimes,
      'max_file_size_mb', v_row.max_file_size_mb,
      'supported_file_mimes', v_row.supported_file_mimes,
      'context_window', v_row.context_window,
      'source', 'registry'
    );
  END IF;

  IF p_provider = 'openrouter'::data.ai_provider AND position('/' IN v_model) > 0 THEN
    v_inner := split_part(v_model, '/', 2);
    v_map := CASE lower(split_part(v_model, '/', 1))
      WHEN 'google' THEN 'gemini'::data.ai_provider
      WHEN 'anthropic' THEN 'anthropic'::data.ai_provider
      WHEN 'openai' THEN 'openai'::data.ai_provider
      ELSE NULL
    END;

    IF v_map IS NOT NULL AND v_inner <> '' THEN
      SELECT * INTO v_row
      FROM data.ai_model_capabilities c
      WHERE c.provider = v_map
        AND c.model_id = v_inner
        AND c.deprecated_at IS NULL;

      IF FOUND THEN
        RETURN jsonb_build_object(
          'provider', p_provider,
          'model_id', v_model,
          'vision', v_row.vision,
          'tools', v_row.tools,
          'tools_with_vision', v_row.tools_with_vision,
          'streaming', v_row.streaming,
          'max_image_size_mb', v_row.max_image_size_mb,
          'supported_image_mimes', v_row.supported_image_mimes,
          'max_file_size_mb', v_row.max_file_size_mb,
          'supported_file_mimes', v_row.supported_file_mimes,
          'context_window', v_row.context_window,
          'source', 'registry_alias'
        );
      END IF;
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

NOTIFY pgrst, 'reload schema';
