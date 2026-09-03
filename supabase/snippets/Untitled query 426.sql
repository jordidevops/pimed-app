SELECT mode, docuseal_api_url, is_active 
FROM data.tenant_signing_config 
LIMIT 5;

SELECT docuseal_submission_id, status, created_at 
FROM data.signing_submissions 
ORDER BY created_at DESC LIMIT 5;