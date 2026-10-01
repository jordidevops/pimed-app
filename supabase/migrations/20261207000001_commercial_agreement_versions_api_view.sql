-- CF-21: refresh api.commercial_agreement_versions after columns added on data.*
-- Postgres expands SELECT * at CREATE VIEW time; later ALTERs (notice_days, SLA,
-- billing, auto_renew) never appear in the api view until it is recreated.
-- That caused PostgREST 400: column commercial_agreement_versions.notice_days
-- does not exist (ContactAgreementsList / ProjectAgreementsSection).

CREATE OR REPLACE VIEW api.commercial_agreement_versions
  WITH (security_invoker = true) AS
SELECT *
FROM data.commercial_agreement_versions
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreement_versions TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
