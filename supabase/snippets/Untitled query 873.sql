-- 1. Obrim una transacció perquè la simulació d'usuari només duri el que dura aquest bloc
BEGIN;

-- 2. Simulem que som un usuari loguejat a l'aplicació
SET LOCAL role = 'authenticated';
SET LOCAL "request.jwt.claims" = '{"sub": "20000000-0000-0000-0000-000000000002", "role": "authenticated"}';

-- 3. Executem la funció (ara data.my_role_in() sí que ens reconeixerà)
SELECT api.enqueue_email('{
  "tenant_id": "10000000-0000-0000-0000-000000000001",
  "idempotency_key": "prova-arq-005",
  "from_email": "noreply@test.myapp.com",
  "to": ["sistema@myapp.com""],
  "subject": "Prova Asíncrona del SaaS 5",
  "html_body": "<h2>Funciona!</h2><p>El Worker asíncron ha agafat aquest correu de pgmq i l''ha enviat.</p>"
}'::jsonb);

-- 4. Confirmem l'operació
COMMIT;