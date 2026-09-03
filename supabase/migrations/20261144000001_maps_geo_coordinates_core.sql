-- =============================================================================
-- Maps / geocoding BYOK — structured address + geo_coordinates on sites & contact_sites
-- Plan: docs/plans/maps-geocoding-byok/README.md §5.1 / §5.1b
-- =============================================================================

-- ─── contact_sites ───────────────────────────────────────────────────────────

ALTER TABLE data.contact_sites
  ADD COLUMN IF NOT EXISTS street          text,
  ADD COLUMN IF NOT EXISTS street_number   text,
  ADD COLUMN IF NOT EXISTS province        text,
  ADD COLUMN IF NOT EXISTS geo_coordinates jsonb;

COMMENT ON COLUMN data.contact_sites.geo_coordinates IS
  'Canonical GeoCoordinates: {lat,lng,street,street_number,city,province,postal_code,country_code,address,geocoding:{provider,source,providerData}}';

CREATE OR REPLACE FUNCTION data.set_contact_site_denormalized_address()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data, public
AS $$
DECLARE
  v_parts text[];
BEGIN
  v_parts := ARRAY[]::text[];
  IF NEW.street IS NOT NULL AND btrim(NEW.street) <> '' THEN
    IF NEW.street_number IS NOT NULL AND btrim(NEW.street_number) <> '' THEN
      v_parts := array_append(v_parts, btrim(NEW.street) || ' ' || btrim(NEW.street_number));
    ELSE
      v_parts := array_append(v_parts, btrim(NEW.street));
    END IF;
  ELSIF NEW.street_number IS NOT NULL AND btrim(NEW.street_number) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.street_number));
  END IF;
  IF NEW.postal_code IS NOT NULL AND btrim(NEW.postal_code) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.postal_code));
  END IF;
  IF NEW.city IS NOT NULL AND btrim(NEW.city) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.city));
  END IF;
  IF NEW.province IS NOT NULL AND btrim(NEW.province) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.province));
  END IF;

  IF cardinality(v_parts) > 0 THEN
    NEW.address := array_to_string(v_parts, ', ');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contact_site_denormalized_address ON data.contact_sites;
CREATE TRIGGER trg_contact_site_denormalized_address
  BEFORE INSERT OR UPDATE OF street, street_number, city, province, postal_code
  ON data.contact_sites
  FOR EACH ROW
  EXECUTE FUNCTION data.set_contact_site_denormalized_address();

-- ─── sites ───────────────────────────────────────────────────────────────────

ALTER TABLE data.sites
  ADD COLUMN IF NOT EXISTS street          text,
  ADD COLUMN IF NOT EXISTS street_number   text,
  ADD COLUMN IF NOT EXISTS city            text,
  ADD COLUMN IF NOT EXISTS province        text,
  ADD COLUMN IF NOT EXISTS postal_code     text,
  ADD COLUMN IF NOT EXISTS country_code    text,
  ADD COLUMN IF NOT EXISTS geo_coordinates jsonb;

COMMENT ON COLUMN data.sites.geo_coordinates IS
  'Canonical GeoCoordinates (promoted from metadata.geo_coordinates). Do not store GPS in metadata.';

-- Backfill geo from metadata variants used by SitesSettingsSection
UPDATE data.sites s
SET geo_coordinates = COALESCE(
  s.geo_coordinates,
  CASE
    WHEN s.metadata ? 'geo_coordinates'
      AND jsonb_typeof(s.metadata->'geo_coordinates') = 'object'
      THEN s.metadata->'geo_coordinates'
    WHEN (s.metadata ? 'lat' OR s.metadata ? 'latitude')
      AND (s.metadata ? 'lng' OR s.metadata ? 'lon' OR s.metadata ? 'longitude')
      THEN jsonb_build_object(
        'lat', COALESCE((s.metadata->>'lat')::float8, (s.metadata->>'latitude')::float8),
        'lng', COALESCE(
          (s.metadata->>'lng')::float8,
          (s.metadata->>'lon')::float8,
          (s.metadata->>'longitude')::float8
        ),
        'address', s.address
      )
    ELSE NULL
  END
)
WHERE s.geo_coordinates IS NULL
  AND s.metadata IS NOT NULL;

CREATE OR REPLACE FUNCTION data.set_site_denormalized_address()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data, public
AS $$
DECLARE
  v_parts text[];
BEGIN
  v_parts := ARRAY[]::text[];
  IF NEW.street IS NOT NULL AND btrim(NEW.street) <> '' THEN
    IF NEW.street_number IS NOT NULL AND btrim(NEW.street_number) <> '' THEN
      v_parts := array_append(v_parts, btrim(NEW.street) || ' ' || btrim(NEW.street_number));
    ELSE
      v_parts := array_append(v_parts, btrim(NEW.street));
    END IF;
  ELSIF NEW.street_number IS NOT NULL AND btrim(NEW.street_number) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.street_number));
  END IF;
  IF NEW.postal_code IS NOT NULL AND btrim(NEW.postal_code) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.postal_code));
  END IF;
  IF NEW.city IS NOT NULL AND btrim(NEW.city) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.city));
  END IF;
  IF NEW.province IS NOT NULL AND btrim(NEW.province) <> '' THEN
    v_parts := array_append(v_parts, btrim(NEW.province));
  END IF;

  IF cardinality(v_parts) > 0 THEN
    NEW.address := array_to_string(v_parts, ', ');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_site_denormalized_address ON data.sites;
CREATE TRIGGER trg_site_denormalized_address
  BEFORE INSERT OR UPDATE OF street, street_number, city, province, postal_code
  ON data.sites
  FOR EACH ROW
  EXECUTE FUNCTION data.set_site_denormalized_address();
