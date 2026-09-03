SELECT key, is_enabled, rollout_percentage
FROM data.feature_flags
WHERE key = 'tenant_signing_enabled';