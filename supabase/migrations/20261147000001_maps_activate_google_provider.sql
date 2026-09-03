-- Activate Google geocoding provider after proxy implements googleSearch/Reverse (S3).
-- Safe to re-run; only flips is_active.

UPDATE data.geocoding_providers
SET is_active = true,
    updated_at = now()
WHERE provider_key = 'google';
