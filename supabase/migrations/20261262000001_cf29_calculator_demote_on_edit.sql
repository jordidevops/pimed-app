-- CF-29 fase 6: editar a mà una línia de calculadora → manual + neteja provenance.

CREATE OR REPLACE FUNCTION data.trg_demote_calculator_line_on_edit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
BEGIN
  IF OLD.line_origin IS DISTINCT FROM 'calculator' THEN
    RETURN NEW;
  END IF;

  IF NEW.line_origin IS DISTINCT FROM 'calculator' THEN
    RETURN NEW;
  END IF;

  IF NEW.name IS DISTINCT FROM OLD.name
     OR NEW.description IS DISTINCT FROM OLD.description
     OR NEW.unit IS DISTINCT FROM OLD.unit
     OR NEW.quantity IS DISTINCT FROM OLD.quantity
     OR NEW.unit_price IS DISTINCT FROM OLD.unit_price
     OR NEW.discount_pct IS DISTINCT FROM OLD.discount_pct
     OR NEW.tax_rate IS DISTINCT FROM OLD.tax_rate
     OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.catalog_item_id IS DISTINCT FROM OLD.catalog_item_id
  THEN
    NEW.line_origin := 'manual';
    NEW.calculator_definition_id := NULL;
    NEW.calculator_version_id := NULL;
    NEW.calculator_line_key := NULL;
    NEW.source_run_id := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_lines_demote_calculator ON data.project_lines;
CREATE TRIGGER trg_project_lines_demote_calculator
  BEFORE UPDATE ON data.project_lines
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_demote_calculator_line_on_edit();

DROP TRIGGER IF EXISTS trg_cdl_demote_calculator ON data.commercial_document_lines;
CREATE TRIGGER trg_cdl_demote_calculator
  BEFORE UPDATE ON data.commercial_document_lines
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_demote_calculator_line_on_edit();
