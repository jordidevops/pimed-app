-- Expose preferred_locale on contacts / contact_sites API views + setter RPCs
-- Note: CREATE OR REPLACE VIEW can only APPEND columns; place preferred_locale last.

CREATE OR REPLACE VIEW api.contacts
  WITH (security_invoker = true) AS
  SELECT
    c.id,
    c.tenant_id,
    c.site_id,
    c.kind,
    c.display_name,
    c.given_name,
    c.family_name,
    c.legal_name,
    c.tax_id,
    c.email,
    c.phone,
    c.phone_alt,
    c.preferred_channel,
    c.tags,
    c.metadata,
    c.source,
    c.owner_user_id,
    c.primary_contact_id,
    c.billing_contact_id,
    c.consent_marketing,
    c.consent_marketing_at,
    c.consent_reminders,
    c.consent_reminders_at,
    c.is_archived,
    c.created_by,
    c.created_at,
    c.updated_at,
    p.full_name AS owner_display_name,
    pc.display_name AS primary_contact_display_name,
    c.preferred_locale
  FROM data.contacts c
  LEFT JOIN data.profiles p ON p.id = c.owner_user_id
  LEFT JOIN data.contacts pc ON pc.id = c.primary_contact_id
  WHERE c.tenant_id = data.active_tenant_id()
    AND c.is_archived = false;

GRANT SELECT ON api.contacts TO authenticated, service_role;

CREATE OR REPLACE VIEW api.contact_sites
  WITH (security_invoker = true) AS
  SELECT
    id,
    tenant_id,
    contact_id,
    name,
    address,
    street,
    street_number,
    city,
    province,
    postal_code,
    country_code,
    geo_coordinates,
    notes,
    is_active,
    created_at,
    updated_at,
    preferred_locale
  FROM data.contact_sites cs
  WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.contact_sites TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_contact_preferred_locale(
  p_contact_id uuid,
  p_locale text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_locale IS NOT NULL AND p_locale NOT IN ('ca','es','en') THEN
    RAISE EXCEPTION 'invalid_locale' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.contacts
  SET preferred_locale = p_locale, updated_at = now()
  WHERE id = p_contact_id
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_not_found_or_forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_contact_preferred_locale(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_contact_site_preferred_locale(
  p_contact_site_id uuid,
  p_locale text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_locale IS NOT NULL AND p_locale NOT IN ('ca','es','en') THEN
    RAISE EXCEPTION 'invalid_locale' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.contact_sites
  SET preferred_locale = p_locale, updated_at = now()
  WHERE id = p_contact_site_id
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_site_not_found_or_forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_contact_site_preferred_locale(uuid, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
