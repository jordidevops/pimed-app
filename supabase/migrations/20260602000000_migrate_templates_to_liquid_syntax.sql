-- Migration: 20260602000000_migrate_templates_to_liquid_syntax.sql
-- ─────────────────────────────────────────────────────────────────────────────
-- Converteix la sintaxi legacy de plantilles (Handlebars-like) a LiquidJS.
--
-- Conversions aplicades:
--   {{#if key}}     → {% if key %}
--   {{/if}}         → {% endif %}
--   {{#unless key}} → {% unless key %}
--   {{/unless}}     → {% endunless %}
--
-- Variables simples {{key}} no es toquen: LiquidJS les accepta tal qual.
-- DOCX: tags de DocuSeal {{Field;role=...}} tampoc es toquen (no coincideixen
--       amb els patrons de conversió).
--
-- Taules afectades:
--   data.email_templates           (subject_template, html_body_template, text_body_template, translations)
--   data.document_template_locales (html_content)
-- ─────────────────────────────────────────────────────────────────────────────

-- ---------------------------------------------------------------------------
-- Helper: funció de conversió de sintaxi
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data._migrate_template_to_liquid(tmpl text)
RETURNS text
LANGUAGE plpgsql AS
$$
BEGIN
  IF tmpl IS NULL THEN
    RETURN NULL;
  END IF;

  -- {{#if key}} → {% if key %}
  tmpl := regexp_replace(tmpl,
    '\{\{#if\s+([a-zA-Z0-9_.]+)\s*\}\}',
    '{% if \1 %}',
    'g'
  );

  -- {{/if}} → {% endif %}
  tmpl := regexp_replace(tmpl,
    '\{\{/if\}\}',
    '{% endif %}',
    'g'
  );

  -- {{#unless key}} → {% unless key %}
  tmpl := regexp_replace(tmpl,
    '\{\{#unless\s+([a-zA-Z0-9_.]+)\s*\}\}',
    '{% unless \1 %}',
    'g'
  );

  -- {{/unless}} → {% endunless %}
  tmpl := regexp_replace(tmpl,
    '\{\{/unless\}\}',
    '{% endunless %}',
    'g'
  );

  RETURN tmpl;
END;
$$;

-- ---------------------------------------------------------------------------
-- Migrar data.email_templates
-- ---------------------------------------------------------------------------
UPDATE data.email_templates
SET
  subject_template    = data._migrate_template_to_liquid(subject_template),
  html_body_template  = data._migrate_template_to_liquid(html_body_template),
  text_body_template  = data._migrate_template_to_liquid(text_body_template)
WHERE
  subject_template   IS NOT NULL
  OR html_body_template IS NOT NULL
  OR text_body_template IS NOT NULL;

-- Migrar camp translations (JSONB: { locale: { subject, html, text } })
UPDATE data.email_templates
SET translations = (
  SELECT jsonb_object_agg(
    locale_key,
    jsonb_build_object(
      'subject', data._migrate_template_to_liquid(locale_val->>'subject'),
      'html',    data._migrate_template_to_liquid(locale_val->>'html'),
      'text',    data._migrate_template_to_liquid(locale_val->>'text')
    )
  )
  FROM jsonb_each(translations) AS t(locale_key, locale_val)
)
WHERE translations IS NOT NULL AND translations <> '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- Migrar data.document_template_locales (html_content)
-- ---------------------------------------------------------------------------
UPDATE data.document_template_locales
SET html_content = data._migrate_template_to_liquid(html_content)
WHERE html_content IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Netejar funció helper (no cal mantenir-la permanentment)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS data._migrate_template_to_liquid(text);
