-- 1) Extension (if not already present)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2) Tenants
CREATE TABLE IF NOT EXISTS tenants (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name text NOT NULL,
  slug text UNIQUE,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived boolean NOT NULL DEFAULT false
);

-- 3) Users (profiles)
CREATE TABLE IF NOT EXISTS user_profiles (
  id uuid PRIMARY KEY, -- should match auth.users.id (supabase)
  email text,
  full_name text,
  phone text,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 4) User <-> Tenant membership (roles per tenant)
CREATE TABLE IF NOT EXISTS user_tenants (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member', -- tenant_admin, technician, inspector, customer, viewer
  is_owner boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

-- 5) Sites (physical locations)
CREATE TABLE IF NOT EXISTS sites (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name text NOT NULL,
  address text,
  city text,
  region text,
  country text,
  postal_code text,
  timezone text,
  metadata jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived boolean NOT NULL DEFAULT false
);

-- 6) Elevators
CREATE TABLE IF NOT EXISTS elevators (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  site_id uuid NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  name text, -- e.g., "Elevator A"
  serial_number text,
  model text,
  manufacturer text,
  capacity integer,
  installation_date date,
  last_inspection_at timestamptz,
  status text DEFAULT 'active', -- active, inactive, decommissioned
  metadata jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived boolean NOT NULL DEFAULT false,
  UNIQUE (tenant_id, serial_number)
);

-- 7) Parts (tenant-scoped parts catalog)
CREATE TABLE IF NOT EXISTS parts (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  sku text,
  name text NOT NULL,
  description text,
  unit_cost numeric(12,2),
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 8) Inventory (stock per site)
CREATE TABLE IF NOT EXISTS inventory_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  site_id uuid REFERENCES sites(id),
  part_id uuid NOT NULL REFERENCES parts(id) ON DELETE RESTRICT,
  quantity integer NOT NULL DEFAULT 0,
  minimum_threshold integer NOT NULL DEFAULT 0,
  metadata jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, site_id, part_id)
);

-- 9) Work orders
CREATE TYPE work_order_status AS ENUM (
  'draft', 'scheduled', 'in_progress', 'completed', 'canceled'
);

CREATE TYPE work_order_priority AS ENUM ('low','medium','high','urgent');

CREATE TABLE IF NOT EXISTS work_orders (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  site_id uuid REFERENCES sites(id) ON DELETE SET NULL,
  elevator_id uuid REFERENCES elevators(id) ON DELETE SET NULL,
  title text NOT NULL,
  description text,
  status work_order_status NOT NULL DEFAULT 'draft',
  priority work_order_priority NOT NULL DEFAULT 'medium',
  requested_by uuid, -- customer or user id
  scheduled_start timestamptz,
  scheduled_end timestamptz,
  recurring_rule text, -- iCal RRULE or custom recurrence metadata
  sla_due_at timestamptz,
  estimated_hours numeric(6,2),
  actual_hours numeric(6,2),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived boolean NOT NULL DEFAULT false
);

-- 10) Work order assignments (technicians)
CREATE TABLE IF NOT EXISTS work_order_assignments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  work_order_id uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES user_profiles(id) ON DELETE SET NULL,
  role text NOT NULL DEFAULT 'technician', -- technician, inspector, lead
  assigned_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  notes text
);

-- 11) Inspections
CREATE TABLE IF NOT EXISTS inspections (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  elevator_id uuid NOT NULL REFERENCES elevators(id) ON DELETE CASCADE,
  work_order_id uuid REFERENCES work_orders(id) ON DELETE SET NULL,
  inspector_id uuid REFERENCES user_profiles(id) ON DELETE SET NULL,
  performed_at timestamptz NOT NULL DEFAULT now(),
  result jsonb, -- structured inspection findings
  score integer,
  recommendations text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 12) Parts used on work orders (many-to-many)
CREATE TABLE IF NOT EXISTS work_order_parts (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  work_order_id uuid NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
  part_id uuid NOT NULL REFERENCES parts(id) ON DELETE RESTRICT,
  quantity integer NOT NULL DEFAULT 1,
  unit_cost numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 13) Events / Notes (activity feed)
CREATE TABLE IF NOT EXISTS events (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  related_type text NOT NULL, -- 'work_order','elevator','inspection','site',etc
  related_id uuid NOT NULL,
  event_type text NOT NULL, -- 'status_change','comment','assignment','inspection_result',etc
  payload jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 14) Attachments (storage references)
CREATE TABLE IF NOT EXISTS attachments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  related_type text NOT NULL, -- work_order, elevator, inspection
  related_id uuid NOT NULL,
  storage_path text NOT NULL, -- e.g., bucket/folder/object or full URL
  filename text,
  content_type text,
  uploaded_by uuid,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);

-- 15) Audit log (simple)
CREATE TABLE IF NOT EXISTS audit_logs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id uuid,
  user_id uuid,
  action text NOT NULL,
  object_type text,
  object_id uuid,
  payload jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 16) Helpful indexes
CREATE INDEX IF NOT EXISTS idx_sites_tenant ON sites(tenant_id);
CREATE INDEX IF NOT EXISTS idx_elevators_tenant ON elevators(tenant_id);
CREATE INDEX IF NOT EXISTS idx_elevators_site ON elevators(site_id);
CREATE INDEX IF NOT EXISTS idx_work_orders_tenant ON work_orders(tenant_id);
CREATE INDEX IF NOT EXISTS idx_work_orders_status ON work_orders(status);
CREATE INDEX IF NOT EXISTS idx_work_orders_scheduled ON work_orders(scheduled_start, scheduled_end);
CREATE INDEX IF NOT EXISTS idx_inspections_elevator ON inspections(elevator_id);
CREATE INDEX IF NOT EXISTS idx_inventory_tenant_site ON inventory_items(tenant_id, site_id);
CREATE INDEX IF NOT EXISTS idx_user_tenants_user ON user_tenants(user_id);

-- 17) Helper function to get tenant(s) for current user (optional)
-- If your JWT does NOT include tenant_id, use this function in policies.
CREATE OR REPLACE FUNCTION get_user_tenants(p_user_id uuid)
RETURNS TABLE(tenant_id uuid) LANGUAGE sql STABLE AS $$
  SELECT tenant_id FROM user_tenants WHERE user_id = p_user_id;
$$;

REVOKE EXECUTE ON FUNCTION get_user_tenants(uuid) FROM anon, authenticated;

-- 18) Enable RLS on tenant-scoped tables
ALTER TABLE sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE elevators ENABLE ROW LEVEL SECURITY;
ALTER TABLE parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_order_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE inspections ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_order_parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- 19) RLS POLICIES
-- Convention: JWT claim 'role' for system role and 'tenant_id' for tenant context (if present).
-- A helper: (SELECT auth.uid()) is the current user's UUID.

-- Superadmin bypass: allow users with JWT role = 'superadmin' to read everything
-- We'll use policies that allow READ/WRITE to tenant members with checks, and explicitly allow superadmin.

-- SITES: allow tenant members read; tenant_admins can insert/update/delete
CREATE POLICY "sites_tenant_read" ON sites
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM get_user_tenants((SELECT auth.uid())) WHERE tenant_id = sites.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "sites_tenant_insert" ON sites
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = sites.tenant_id AND ut.role IN ('tenant_admin','owner'))
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "sites_tenant_update" ON sites
  FOR UPDATE
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = sites.tenant_id AND ut.role IN ('tenant_admin','owner'))
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "sites_tenant_delete" ON sites
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = sites.tenant_id AND ut.role IN ('tenant_admin','owner'))
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- ELEVATORS: tenant members can SELECT; tenant_admin and technicians can insert/update; only tenant_admin can delete
CREATE POLICY "elevators_read" ON elevators
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = elevators.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "elevators_insert" ON elevators
  FOR INSERT
  TO authenticated
  WITH CHECK (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = elevators.tenant_id AND ut.role IN ('tenant_admin','technician'))
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "elevators_update" ON elevators
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = elevators.tenant_id AND ut.role IN ('tenant_admin','technician'))
    OR (auth.jwt() ->> 'role') = 'superadmin'
  )
  WITH CHECK (
    elevators.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "elevators_delete" ON elevators
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = elevators.tenant_id AND ut.role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- WORK_ORDERS: Complex; allow:
-- - SELECT: tenant members (customers can see their requested ones), technicians see assigned ones
-- - INSERT: tenant_admin, customer (with tenant membership)
-- - UPDATE: assigned technicians (for status changes), tenant_admin
-- - DELETE: tenant_admin

-- SELECT policy (broad tenant visibility to tenant members)
CREATE POLICY "work_orders_select" ON work_orders
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = work_orders.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- INSERT policy
CREATE POLICY "work_orders_insert" ON work_orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    work_orders.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      (auth.jwt() ->> 'role') IN ('tenant_admin','customer')
      OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_orders.tenant_id AND ut.role IN ('tenant_admin','customer'))
      OR (auth.jwt() ->> 'role') = 'superadmin'
    )
  );

-- UPDATE policy
CREATE POLICY "work_orders_update" ON work_orders
  FOR UPDATE
  TO authenticated
  USING (
    -- allow if tenant admin or assigned technician or superadmin
    (EXISTS (
      SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_orders.tenant_id AND ut.role IN ('tenant_admin')
    ))
    OR EXISTS (
      SELECT 1 FROM work_order_assignments wa WHERE wa.work_order_id = work_orders.id AND wa.user_id = (SELECT auth.uid())
    )
    OR (auth.jwt() ->> 'role') = 'superadmin'
  )
  WITH CHECK (
    work_orders.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- DELETE policy
CREATE POLICY "work_orders_delete" ON work_orders
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_orders.tenant_id AND ut.role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- WORK_ORDER_ASSIGNMENTS: tenant admins can assign; assigned techs can select their assignments
CREATE POLICY "wo_assignments_select" ON work_order_assignments
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = work_order_assignments.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "wo_assignments_insert" ON work_order_assignments
  FOR INSERT
  TO authenticated
  WITH CHECK (
    work_order_assignments.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      (auth.jwt() ->> 'role') IN ('tenant_admin')
      OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_order_assignments.tenant_id AND ut.role = 'tenant_admin')
      OR (auth.jwt() ->> 'role') = 'superadmin'
    )
  );

CREATE POLICY "wo_assignments_update" ON work_order_assignments
  FOR UPDATE
  TO authenticated
  USING (
    -- assigned user or tenant admin
    (work_order_assignments.user_id = (SELECT auth.uid()))
    OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_order_assignments.tenant_id AND ut.role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "wo_assignments_delete" ON work_order_assignments
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = work_order_assignments.tenant_id AND ut.role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- INSPECTIONS: inspectors and tenant admins and assigned technicians can insert/select
CREATE POLICY "inspections_select" ON inspections
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = inspections.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "inspections_insert" ON inspections
  FOR INSERT
  TO authenticated
  WITH CHECK (
    inspections.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND (
      (auth.jwt() ->> 'role') IN ('inspector','tenant_admin')
      OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = inspections.tenant_id AND ut.role IN ('inspector','tenant_admin'))
      OR (auth.jwt() ->> 'role') = 'superadmin'
    )
  );

CREATE POLICY "inspections_update" ON inspections
  FOR UPDATE
  TO authenticated
  USING (
    (inspections.inspector_id = (SELECT auth.uid()))
    OR EXISTS (SELECT 1 FROM user_tenants ut WHERE ut.user_id = (SELECT auth.uid()) AND ut.tenant_id = inspections.tenant_id AND ut.role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- EVENTS & ATTACHMENTS: tenant members can create/read; tenant_admins moderate/delete
CREATE POLICY "events_select" ON events
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = events.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "events_insert" ON events
  FOR INSERT
  TO authenticated
  WITH CHECK (
    events.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = events.tenant_id)
  );

CREATE POLICY "events_delete" ON events
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = events.tenant_id AND role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "attachments_select" ON attachments
  FOR SELECT
  TO authenticated
  USING (
    tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = attachments.tenant_id)
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT
  TO authenticated
  WITH CHECK (
    attachments.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
    AND EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = attachments.tenant_id)
  );

CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = attachments.tenant_id AND role = 'tenant_admin')
    OR (auth.jwt() ->> 'role') = 'superadmin'
  );

-- AUDIT LOGS: only system/service role or tenant admins can insert (service role bypasses RLS in Supabase)
CREATE POLICY "audit_insert" ON audit_logs
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (auth.jwt() ->> 'role') = 'superadmin'
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = audit_logs.tenant_id AND role = 'tenant_admin')
    OR audit_logs.tenant_id IS NULL
  );

CREATE POLICY "audit_select" ON audit_logs
  FOR SELECT
  TO authenticated
  USING (
    (auth.jwt() ->> 'role') = 'superadmin'
    OR (audit_logs.tenant_id IS NULL)
    OR EXISTS (SELECT 1 FROM user_tenants WHERE user_id = (SELECT auth.uid()) AND tenant_id = audit_logs.tenant_id)
  );

-- 20) Final note: grant privileges to the authenticated role for basic operations (optional)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;