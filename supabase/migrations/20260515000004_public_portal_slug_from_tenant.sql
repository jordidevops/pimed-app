-- =============================================================================
-- Migration: 20260515000004_public_portal_slug_from_tenant.sql
-- Propòsit : Eliminar el slug lliure al crear un portal públic.
--            El slug del public_site es deriva automàticament de tenants.slug,
--            que ja és UNIQUE NOT NULL i assignat per l'admin en crear el tenant.
--
-- Motivació:
--   Permetre als usuaris triar el slug lliurement permet:
--   1. Slug squatting: un tenant pot reclamar el slug abandonat per un altre.
--   2. Conflicte de marca: un tenant pot reclamar el nom d'un altre.
--   3. Inconsistència: el slug del portal podria no correspondre al tenant.
--
--   Derivar-lo de tenants.slug resol tots tres problemes:
--   · tenants.slug ja és UNIQUE NOT NULL i validat per la startup en crear tenant.
--   · Un tenant no pot tenir mai un portal amb el slug d'un altre tenant.
--   · El canvi de slug requereix intervenció admin (canviar tenants.slug).
--
-- Canvis:
--   1.  REPLACE: api.create_public_site(p_slug, p_name, p_site_id)
--       → api.create_public_site(p_name, p_site_id)
--       El slug es deriva internament de data.tenants.slug del tenant actiu.
--
-- Nota sobre la ruta per slug (producció):
--   · url: /<slug>  → deriva de tenants.slug, no canvia mai sense intervenció admin.
--   · La ruta per custom domain (_sites/[domain]) NO es veu afectada.
--
-- Dependències:
--   · data.public_sites       (20260513000001)
--   · data.tenants.slug       (20260401000002) — UNIQUE NOT NULL
--   · data.active_tenant_id() (20260401000002)
-- =============================================================================

-- Substituïm la funció. DROP IF EXISTS per evitar conflicte de signatura.
DROP FUNCTION IF EXISTS api.create_public_site(text, text, uuid);

CREATE OR REPLACE FUNCTION api.create_public_site(
  p_name      text,
  p_site_id   uuid  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id        uuid;
  v_tenant_id uuid := data.active_tenant_id();
  v_slug      text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'missing_tenant_context'
      USING HINT = 'Envia la capçalera x-tenant-id amb el UUID del tenant.';
  END IF;

  -- Deriva el slug del tenant: garantit UNIQUE per UNIQUE INDEX de data.tenants.slug
  SELECT lower(trim(t.slug))
  INTO v_slug
  FROM data.tenants t
  WHERE t.id = v_tenant_id;

  IF v_slug IS NULL THEN
    RAISE EXCEPTION 'tenant_slug_missing'
      USING HINT = 'El tenant no té un slug assignat. Configura-ho des de l''admin.';
  END IF;

  INSERT INTO data.public_sites (
    tenant_id,
    site_id,
    slug,
    name,
    status,
    created_by
  ) VALUES (
    v_tenant_id,
    p_site_id,
    v_slug,
    p_name,
    'draft',
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_public_site(text, uuid) TO authenticated;

COMMENT ON FUNCTION api.create_public_site IS
  'Crea un portal públic (public_site) per al tenant actiu. '
  'El slug es deriva automàticament de data.tenants.slug (UNIQUE NOT NULL), '
  'eliminant la possibilitat de slug squatting entre tenants. '
  'L''usuari no pot triar el slug; requereix intervenció admin per canviar-lo '
  '(actualitzant data.tenants.slug, que afecta el routing del portal). '
  'SECURITY INVOKER: la policy INSERT de data.public_sites valida el rol.';
