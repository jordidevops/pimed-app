-- =============================================================================
-- REC-1 follow-up — recruitment-cvs storage policies
-- Upload públic només via service_role (API Next). HR pot llegir amb recruitment.view.
-- Path: {public_site_id}/{job_posting_id}/{file}
-- =============================================================================

CREATE OR REPLACE FUNCTION data.recruitment_cv_path_public_site(p_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(SPLIT_PART(p_name, '/', 1), '')::uuid;
$$;

DROP POLICY IF EXISTS "recruitment-cvs: lectura HR" ON storage.objects;
CREATE POLICY "recruitment-cvs: lectura HR"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'recruitment-cvs'
    AND EXISTS (
      SELECT 1
      FROM data.public_sites ps
      WHERE ps.id = data.recruitment_cv_path_public_site(name)
        AND data.jwt_has_recruitment_permission(ps.tenant_id, 'recruitment.view')
    )
  );

-- Sense policies INSERT/UPDATE/DELETE per authenticated/anon:
-- només service_role pot escriure (route /api/recruitment/apply).
