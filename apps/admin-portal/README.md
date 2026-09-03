Backoffice per a administradors de la plataforma (startup)


Per a crear un usuari executar al SQL Editor:

```sql
UPDATE auth.users
SET raw_app_meta_data = raw_app_meta_data || '{"role": "admin"}'::jsonb
WHERE email = 'admin@example.com';
```



