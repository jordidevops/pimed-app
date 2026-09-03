-- Repair existing platform HTML templates so their default mappings resolve
-- real header/footer blocks in the final rendering path.

DO $$
BEGIN
  -- Generic HTML platform templates: ensure the standard footer and body blocks exist.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category NOT IN ('hr', 'rrhh', 'legal', 'rgpd', 'gdpr', 'iso', 'qualitat', 'quality', 'safety');

  -- HR templates: use the HR-specific header + body mappings.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000012',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000021',
    'document_footer', 'c0000001-0000-4000-b000-000000000030'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('hr', 'rrhh');

  -- ISO / quality / safety templates: use the standard page header plus legal footer.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000011',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('iso', 'qualitat', 'quality', 'safety');

  -- Legal / RGPD templates: use the legal header/footer defaults.
  UPDATE data.document_templates
  SET default_block_mapping = COALESCE(default_block_mapping, '{}'::jsonb) || jsonb_build_object(
    'page_header',     'c0000001-0000-4000-b000-000000000010',
    'page_footer',     'c0000001-0000-4000-b000-000000000002',
    'document_header', 'c0000001-0000-4000-b000-000000000020',
    'document_footer', 'c0000001-0000-4000-b000-000000000031'
  )
  WHERE is_platform_default = true
    AND is_active = true
    AND template_type = 'html'
    AND category IN ('legal', 'rgpd', 'gdpr');
END $$;
