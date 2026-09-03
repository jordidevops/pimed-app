-- Migration: 20260603000013_template_legacy_syntax_guard.sql
-- -----------------------------------------------------------------------------
-- Goal:
--   1) Sanitize any remaining legacy Handlebars-like blocks in template content
--   2) Enforce a hard guard so legacy blocks cannot be saved again
--
-- Legacy blocks rejected after this migration:
--   {{#if ...}}, {{/if}}, {{#unless ...}}, {{/unless}}
--
-- Official syntax allowed:
--   {% if ... %}...{% endif %}, {% unless ... %}...{% endunless %}, {{ var }}
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 1) Helper: migrate legacy blocks to Liquid blocks
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data._migrate_legacy_template_blocks(tmpl text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
  IF tmpl IS NULL THEN
    RETURN NULL;
  END IF;

  tmpl := regexp_replace(
    tmpl,
    '\{\{#if\s+([a-zA-Z0-9_.]+)\s*\}\}',
    '{% if \1 %}',
    'g'
  );

  tmpl := regexp_replace(
    tmpl,
    '\{\{/if\}\}',
    '{% endif %}',
    'g'
  );

  tmpl := regexp_replace(
    tmpl,
    '\{\{#unless\s+([a-zA-Z0-9_.]+)\s*\}\}',
    '{% unless \1 %}',
    'g'
  );

  tmpl := regexp_replace(
    tmpl,
    '\{\{/unless\}\}',
    '{% endunless %}',
    'g'
  );

  RETURN tmpl;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2) Sanitize current rows (idempotent)
-- -----------------------------------------------------------------------------
UPDATE data.email_templates
SET
  subject_template   = data._migrate_legacy_template_blocks(subject_template),
  html_body_template = data._migrate_legacy_template_blocks(html_body_template),
  text_body_template = data._migrate_legacy_template_blocks(text_body_template)
WHERE
  subject_template IS NOT NULL
  OR html_body_template IS NOT NULL
  OR text_body_template IS NOT NULL;

UPDATE data.email_templates
SET translations = (
  SELECT jsonb_object_agg(
    locale_key,
    jsonb_build_object(
      'subject', data._migrate_legacy_template_blocks(locale_val->>'subject'),
      'html',    data._migrate_legacy_template_blocks(locale_val->>'html'),
      'text',    data._migrate_legacy_template_blocks(locale_val->>'text')
    )
  )
  FROM jsonb_each(translations) AS t(locale_key, locale_val)
)
WHERE translations IS NOT NULL
  AND jsonb_typeof(translations) = 'object'
  AND translations <> '{}'::jsonb;

UPDATE data.document_template_locales
SET html_content = data._migrate_legacy_template_blocks(html_content)
WHERE html_content IS NOT NULL;

DROP FUNCTION IF EXISTS data._migrate_legacy_template_blocks(text);

-- -----------------------------------------------------------------------------
-- 3) Guard helpers + trigger function
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data._contains_legacy_template_blocks(tmpl text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    tmpl ~* '\{\{#(if|unless)\b|\{\{/(if|unless)\}\}',
    false
  );
$$;

CREATE OR REPLACE FUNCTION data.trg_reject_legacy_template_blocks()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_locale_key text;
  v_locale_val jsonb;
BEGIN
  IF TG_TABLE_NAME = 'email_templates' THEN
    IF data._contains_legacy_template_blocks(NEW.subject_template) THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Legacy template syntax is not allowed in subject_template',
        HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
    END IF;

    IF data._contains_legacy_template_blocks(NEW.html_body_template) THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Legacy template syntax is not allowed in html_body_template',
        HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
    END IF;

    IF data._contains_legacy_template_blocks(NEW.text_body_template) THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Legacy template syntax is not allowed in text_body_template',
        HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
    END IF;

    IF NEW.translations IS NOT NULL AND jsonb_typeof(NEW.translations) = 'object' THEN
      FOR v_locale_key, v_locale_val IN
        SELECT key, value FROM jsonb_each(NEW.translations)
      LOOP
        IF data._contains_legacy_template_blocks(v_locale_val->>'subject') THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = format('Legacy template syntax is not allowed in translations.%s.subject', v_locale_key),
            HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
        END IF;

        IF data._contains_legacy_template_blocks(v_locale_val->>'html') THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = format('Legacy template syntax is not allowed in translations.%s.html', v_locale_key),
            HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
        END IF;

        IF data._contains_legacy_template_blocks(v_locale_val->>'text') THEN
          RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = format('Legacy template syntax is not allowed in translations.%s.text', v_locale_key),
            HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
        END IF;
      END LOOP;
    END IF;

  ELSIF TG_TABLE_NAME = 'document_template_locales' THEN
    IF data._contains_legacy_template_blocks(NEW.html_content) THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Legacy template syntax is not allowed in html_content',
        HINT = 'Use Liquid tags: {% if ... %}...{% endif %} / {% unless ... %}...{% endunless %}';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) Trigger bindings
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_reject_legacy_template_blocks_email
  ON data.email_templates;

CREATE TRIGGER trg_reject_legacy_template_blocks_email
  BEFORE INSERT OR UPDATE OF subject_template, html_body_template, text_body_template, translations
  ON data.email_templates
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_reject_legacy_template_blocks();

DROP TRIGGER IF EXISTS trg_reject_legacy_template_blocks_doc_locales
  ON data.document_template_locales;

CREATE TRIGGER trg_reject_legacy_template_blocks_doc_locales
  BEFORE INSERT OR UPDATE OF html_content
  ON data.document_template_locales
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_reject_legacy_template_blocks();
