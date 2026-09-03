-- Permet comentaris només amb adjunts (sense text)
ALTER TABLE data.entity_comments
  DROP CONSTRAINT IF EXISTS entity_comments_content_not_empty;

ALTER TABLE data.entity_comments
  ADD CONSTRAINT entity_comments_content_not_empty
  CHECK (
    length(trim(content)) > 0
    OR deleted_at IS NOT NULL
    OR jsonb_array_length(attachments) > 0
  );
