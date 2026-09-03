-- =============================================================================
-- Fix CR-6 smoke — site managers poden veure certificacions no-mèdiques
-- Polítiques anteriors només acceptaven global_role owner/manager o permís global.
-- Charlie (seed) és manager només a site Acme Gràcia → 0 files RLS.
-- =============================================================================

DROP POLICY IF EXISTS employee_certifications_select_non_medical ON data.employee_certifications;
CREATE POLICY employee_certifications_select_non_medical ON data.employee_certifications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.compliance_requirement_types t
      WHERE t.id = requirement_type_id
        AND t.category IN ('legal', 'technical', 'other')
    )
    AND (
      data.jwt_has_permission(tenant_id, 'compliance.certifications.view')
      OR data.jwt_has_permission(tenant_id, 'compliance.certifications.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR EXISTS (
        SELECT 1
        FROM data.employees e
        WHERE e.id = employee_id
          AND e.tenant_id = employee_certifications.tenant_id
          AND (
            data.jwt_has_permission(tenant_id, 'compliance.certifications.view', e.site_id)
            OR data.jwt_has_permission(tenant_id, 'compliance.certifications.manage', e.site_id)
            OR (e.site_id IS NOT NULL AND (
              data.jwt_user_tenants() -> tenant_id::text -> 'sites' -> e.site_id::text
            ) IN ('"owner"'::jsonb, '"manager"'::jsonb))
          )
      )
    )
  );

-- Medical: owner global, medical_clearance.*, o owner de site de l'empleat (no manager)
DROP POLICY IF EXISTS employee_certifications_select_medical ON data.employee_certifications;
CREATE POLICY employee_certifications_select_medical ON data.employee_certifications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND EXISTS (
      SELECT 1 FROM data.compliance_requirement_types t
      WHERE t.id = requirement_type_id
        AND t.category = 'medical'
    )
    AND (
      data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.view')
      OR data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
      OR EXISTS (
        SELECT 1
        FROM data.employees e
        WHERE e.id = employee_id
          AND e.tenant_id = employee_certifications.tenant_id
          AND (
            data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.view', e.site_id)
            OR data.jwt_has_permission(tenant_id, 'compliance.medical_clearance.manage', e.site_id)
            OR (e.site_id IS NOT NULL AND (
              data.jwt_user_tenants() -> tenant_id::text -> 'sites' -> e.site_id::text
            ) = '"owner"'::jsonb)
          )
      )
    )
  );
