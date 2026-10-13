-- api.update_contact: editar dades bàsiques del contacte al tenant actiu.
-- SECURITY INVOKER: el UPDATE passa les polítiques RLS de data.contacts.

CREATE OR REPLACE FUNCTION api.update_contact(
  p_contact_id        uuid,
  p_kind              text,
  p_display_name      text,
  p_given_name        text        DEFAULT NULL,
  p_family_name       text        DEFAULT NULL,
  p_legal_name        text        DEFAULT NULL,
  p_tax_id            text        DEFAULT NULL,
  p_email             text        DEFAULT NULL,
  p_phone             text        DEFAULT NULL,
  p_phone_alt         text        DEFAULT NULL,
  p_preferred_channel text        DEFAULT NULL,
  p_tags              text[]      DEFAULT NULL,
  p_source            text        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_updated   int;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required';
  END IF;

  IF p_display_name IS NULL OR btrim(p_display_name) = '' THEN
    RAISE EXCEPTION 'display_name_required';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('person', 'company') THEN
    RAISE EXCEPTION 'invalid_kind';
  END IF;

  UPDATE data.contacts
  SET
    kind = p_kind::data.contact_kind,
    display_name = btrim(p_display_name),
    given_name = NULLIF(btrim(COALESCE(p_given_name, '')), ''),
    family_name = NULLIF(btrim(COALESCE(p_family_name, '')), ''),
    legal_name = NULLIF(btrim(COALESCE(p_legal_name, '')), ''),
    tax_id = NULLIF(btrim(COALESCE(p_tax_id, '')), ''),
    email = NULLIF(btrim(COALESCE(p_email, '')), ''),
    phone = NULLIF(btrim(COALESCE(p_phone, '')), ''),
    phone_alt = NULLIF(btrim(COALESCE(p_phone_alt, '')), ''),
    preferred_channel = COALESCE(
      NULLIF(btrim(COALESCE(p_preferred_channel, '')), ''),
      preferred_channel
    ),
    tags = COALESCE(p_tags, tags),
    source = COALESCE(NULLIF(btrim(COALESCE(p_source, '')), ''), source),
    updated_at = now()
  WHERE id = p_contact_id
    AND tenant_id = v_tenant_id
    AND is_archived = false;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'contact_not_found';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.update_contact(
  uuid, text, text, text, text, text, text, text, text, text, text, text[], text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.update_contact(
  uuid, text, text, text, text, text, text, text, text, text, text, text[], text
) TO authenticated;
