-- Fix: security_invoker views require grants on the underlying data table.

GRANT SELECT, INSERT, UPDATE, DELETE ON data.payroll_export_profiles TO authenticated;
