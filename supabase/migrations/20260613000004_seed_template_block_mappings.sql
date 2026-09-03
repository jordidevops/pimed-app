/*
  Seed: default_block_mapping per a plantilles de plataforma HTML
  ───────────────────────────────────────────────────────────────
  Assigna blocs de sistema (generats a 20260613000002) com a defecte
  per a les plantilles HTML de la plataforma.

  Mapeig:
  - Totes les plantilles HTML de plataforma → peu de pàgina estàndard (c0000001-...0002)
    si no en tenen cap assignat.
  - Les plantilles RRHH de tipus HTML → capçalera corporativa simple (c0000001-...0004)
    i peu de pàgina amb número (c0000001-...0002).
  - Les plantilles ISO/Qualitat → capçalera ISO (c0000001-...0007)
    i peu ISO (c0000001-...0008).

  IDs de blocs de sistema (de 20260613000002):
    c0000001-0000-4000-b000-000000000001  Peu legal estàndard (TEXT)
    c0000001-0000-4000-b000-000000000002  Peu amb número de pàgina (HTML)
    c0000001-0000-4000-b000-000000000003  Peu d'avís de confidencialitat (TEXT)
    c0000001-0000-4000-b000-000000000004  Capçalera corporativa simple (HTML)
    c0000001-0000-4000-b000-000000000005  Capçalera RRHH (HTML)
    c0000001-0000-4000-b000-000000000006  Capçalera RRHH — nòmina (HTML)
    c0000001-0000-4000-b000-000000000007  Capçalera ISO / Qualitat (HTML)
    c0000001-0000-4000-b000-000000000008  Peu ISO / Qualitat (TEXT)
    c0000001-0000-4000-b000-000000000009  Bloc RGPD — base (HTML)
    c0000001-0000-4000-b000-000000000010  Bloc RGPD — detallat (HTML)
    c0000001-0000-4000-b000-000000000011  Avís de confidencialitat (HTML)
    c0000001-0000-4000-b000-000000000012  Clàusula de signatura electrònica (HTML)

  Idempotent: usa jsonb_strip_nulls + OR = OR (no sobreescriu si ja té mapping)
*/

DO $$
DECLARE
  v_id uuid;
BEGIN

  -- ─── Plantilles HTML de plataforma: peu + blocs de cos per defecte ─────
  -- Per a totes les plantilles HTML de plataforma sense mapping assignat.
  UPDATE data.document_templates
  SET default_block_mapping = jsonb_build_object(
    'page_footer',      'c0000001-0000-4000-b000-000000000002',
    'document_header',  'c0000001-0000-4000-b000-000000000020',
    'document_footer',  'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND (template_type = 'html' OR template_type IS NULL)
    AND (default_block_mapping IS NULL OR default_block_mapping = '{}'::jsonb);

  -- ─── RRHH / HR ─────────────────────────────────────────────────────────
  UPDATE data.document_templates
  SET default_block_mapping = jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000012',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000021',
    'document_footer', 'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND category IN ('hr', 'rrhh')
    AND template_type = 'html'
    AND (default_block_mapping IS NULL OR default_block_mapping = '{}'::jsonb);

  -- ─── ISO / Qualitat ──────────────────────────────────────────────────────
  UPDATE data.document_templates
  SET default_block_mapping = jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000011',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND category IN ('iso', 'qualitat', 'quality', 'safety')
    AND template_type = 'html'
    AND (default_block_mapping IS NULL OR default_block_mapping = '{}'::jsonb);

  -- ─── Legal / RGPD ───────────────────────────────────────────────────────
  UPDATE data.document_templates
  SET default_block_mapping = jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000010',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND category IN ('legal', 'rgpd', 'gdpr')
    AND template_type = 'html'
    AND (default_block_mapping IS NULL OR default_block_mapping = '{}'::jsonb);

END;
$$;
