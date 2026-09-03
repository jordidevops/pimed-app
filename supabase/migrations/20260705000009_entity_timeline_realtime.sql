-- Entity Timeline — Realtime (Fase 2, D13)
-- Emet events postgres_changes per comentaris i audit d'una entitat.

ALTER PUBLICATION supabase_realtime ADD TABLE data.entity_comments;
ALTER PUBLICATION supabase_realtime ADD TABLE data.audit_logs;
