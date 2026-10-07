-- CS-D58 hardening leftovers:
-- - remap legacy channels; tighten CHECK
-- - schedule token_once purge via pg_cron

-- ---------------------------------------------------------------------------
-- 1. Channel CHECK: no new whatsapp / copy_link product channels
-- ---------------------------------------------------------------------------
UPDATE data.commercial_decision_deliveries
SET channel = 'whatsapp_portal_nudge'
WHERE channel = 'whatsapp';

-- Historical copy_link rows: keep for audit, but mark as non-product via status note in events is enough.
-- Remap to portal so CHECK can drop copy_link (portal = no bearer, same as nudge semantics for ledger).
UPDATE data.commercial_decision_deliveries
SET channel = 'portal'
WHERE channel = 'copy_link';

ALTER TABLE data.commercial_decision_deliveries
  DROP CONSTRAINT IF EXISTS commercial_decision_deliveries_channel_check;

ALTER TABLE data.commercial_decision_deliveries
  ADD CONSTRAINT commercial_decision_deliveries_channel_check
  CHECK (channel IN (
    'email',
    'whatsapp_portal_nudge',
    'portal',
    'presential'
  ));

-- ---------------------------------------------------------------------------
-- 2. pg_cron: purge expired plaintext tokens hourly
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('purge-commercial-decision-token-once');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'purge-commercial-decision-token-once',
      '20 * * * *',
      $cron$SELECT data.purge_expired_commercial_decision_token_once()$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CS-D58: could not schedule token_once purge cron: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
