-- CF-28 / F5: Un DMS — plantilles quote sense client_reject; validador alineat.
-- El refús comercial no estampa; només client_accept / client_delivery / client (agreement).

CREATE OR REPLACE FUNCTION data.validate_commercial_template_locale(
  p_content text,
  p_mime_type text,
  p_doc_type text
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $validate$
DECLARE
  v_content text := COALESCE(p_content, '');
  v_missing text[] := '{}';
  v_html boolean;
BEGIN
  IF p_doc_type IS NULL OR p_doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;

  IF p_mime_type IS NULL
     OR p_mime_type NOT IN (
       'text/html',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
     ) THEN
    RETURN '{}'::text[];
  END IF;

  v_html := (p_mime_type = 'text/html');

  IF p_doc_type IN ('quote', 'quote_amendment') THEN
    IF v_html THEN
      IF position('{% for line in lines %}' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    ELSE
      IF position('[[#lines]]' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    END IF;

    IF position('totals.total' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'totals.total');
    END IF;
    IF position('document.doc_number' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.doc_number');
    END IF;
    IF position('document.valid_until' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.valid_until');
    END IF;
    IF position('totals.tax_breakdown' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'tax_breakdown');
    END IF;

    IF v_html THEN
      IF position('role="client_accept"' IN v_content) = 0
         AND position($$role='client_accept'$$ IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_accept');
      END IF;
    ELSE
      IF position('role=client_accept' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_accept');
      END IF;
    END IF;
  ELSE
    IF v_html THEN
      IF position('{% for line in lines %}' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    ELSE
      IF position('[[#lines]]' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'lines_loop');
      END IF;
    END IF;

    IF position('document.doc_number' IN v_content) = 0 THEN
      v_missing := array_append(v_missing, 'document.doc_number');
    END IF;

    IF v_html THEN
      IF position('role="client_delivery"' IN v_content) = 0
         AND position($$role='client_delivery'$$ IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_delivery');
      END IF;
    ELSE
      IF position('role=client_delivery' IN v_content) = 0 THEN
        v_missing := array_append(v_missing, 'client_delivery');
      END IF;
    END IF;
  END IF;

  RETURN v_missing;
END;
$validate$;

REVOKE ALL ON FUNCTION data.validate_commercial_template_locale(text, text, text) FROM PUBLIC;

-- Actualitza plantilles platform quote: treu casella client_reject i rol de signing_roles_schema.
UPDATE data.document_template_locales dtl
SET
  html_content = regexp_replace(
    regexp_replace(
      dtl.html_content,
      E'<div>\\s*<div>(Refuso|Rechazo)</div>\\s*<signature-field[^>]*role="client_reject"[^>]*(/>|>\\s*</signature-field>)\\s*</div>',
      '',
      'gi'
    ),
    E'Cal signar una de les dues caselles \\(mateixa mida\\)\\.|Hay que firmar una de las dos casillas \\(mismo tamaño\\)\\.',
    CASE
      WHEN dtl.locale = 'es'
        THEN 'Hay que firmar la casilla de aceptación. El rechazo se hace desde el enlace de decisión, sin firma en el PDF.'
      ELSE 'Cal signar la casella d’acceptació. El refús es fa des de l’enllaç de decisió, sense firma al PDF.'
    END,
    'g'
  ),
  signing_roles_schema = COALESCE(dtl.signing_roles_schema, '{}'::jsonb) - 'client_reject'
FROM data.document_templates dt
WHERE dtl.template_id = dt.id
  AND dt.is_platform_default IS TRUE
  AND dt.category = 'quote'
  AND dtl.html_content LIKE '%client_reject%';
