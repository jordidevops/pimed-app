-- Wire prospect promote/cancel to quote status transitions.

CREATE OR REPLACE FUNCTION data.trg_commercial_document_sync_prospect()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RETURN NEW;
  END IF;
  IF NEW.project_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status IN ('accepted', 'signed') THEN
    PERFORM data.sync_prospect_project_on_quote_decision(NEW.project_id, 'accepted');
  ELSIF NEW.status IN ('rejected', 'expired', 'cancelled') THEN
    PERFORM data.sync_prospect_project_on_quote_decision(NEW.project_id, NEW.status);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_sync_prospect ON data.commercial_documents;
CREATE TRIGGER trg_commercial_document_sync_prospect
  AFTER UPDATE OF status ON data.commercial_documents
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_document_sync_prospect();
