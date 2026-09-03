-- Fix: seed.sql s'executa després de F1 i deixava portal_entitlements = {} als plans.
UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
  'public_portal', jsonb_build_object('included', false, 'cms_tier', 'none', 'max_pages', 3)
) WHERE name = 'free';

UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
  'public_portal', jsonb_build_object('included', true, 'cms_tier', 'basic', 'max_pages', 20)
) WHERE name = 'pro';

UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'advanced'),
  'public_portal', jsonb_build_object('included', true, 'cms_tier', 'advanced', 'max_pages', 0)
) WHERE name = 'enterprise';
