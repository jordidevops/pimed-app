-- =============================================================================
-- Migració: 20261161000001_restore_signing_submissions_update_trigger.sql
-- Propòsit : Restaura el trigger INSTEAD OF UPDATE de api.signing_submissions.
--
-- Conté:
--   1. Recrea trg_api_signing_submissions_update sobre la vista
--
-- Context : 20260615000012 va fer DROP VIEW (i el trigger va caure amb la vista).
--           20260615000013 va actualitzar la funció però no va tornar a crear
--           el trigger. Sense ell, PostgREST retorna
--           "cannot update view signing_submissions".
-- =============================================================================

DROP TRIGGER IF EXISTS trg_api_signing_submissions_update ON api.signing_submissions;

CREATE TRIGGER trg_api_signing_submissions_update
  INSTEAD OF UPDATE ON api.signing_submissions
  FOR EACH ROW EXECUTE FUNCTION data.trg_api_signing_submissions_update();
