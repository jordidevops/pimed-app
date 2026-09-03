# Evidencia E2 - Signing Matrix

Data: 2026-06-02
Entorn: local Supabase + Edge Functions

## Setup executat

1. Edge runtime iniciat amb ruta absoluta d env:
   - supabase functions serve --env-file C:\JordiDevops\app-supabase\supabase\functions\.env.local
2. JWT obtingut amb usuari owner del tenant:
   - alice@acme-corp.com
3. IDs utilitzats per la matriu:
   - EDGE_TEST_TENANT_ID=10000000-0000-0000-0000-000000000001
   - EDGE_TEST_HTML_TEMPLATE_LOCALE_ID=71000000-0000-0000-0000-000000000008
   - EDGE_TEST_DOCX_TEMPLATE_LOCALE_ID=73000000-0000-0000-0000-000000000008
   - EDGE_TEST_PDF_DOCUMENT_VERSION_ID=73e4b65d-9e86-4977-85f8-c17f77570b2c
   - EDGE_TEST_SIGNER_EMAIL=charlie@acme-corp.com

## Execucio matriu E2

Comanda:

- node supabase/tests/edge_signing_matrix_tests.mjs

Resultat:

- PASS | sign/html returns 201
- PASS | sign/docx returns 201
- PASS | sign/pdf returns 201
- PASS | generate_only/html returns 201
- PASS | generate_only/docx returns 201
- PASS | generate_only/pdf returns 201
- Summary: PASS=6 SKIP=0 FAIL=0 TOTAL=6

## Notes tecnniques

1. S ha aplicat fallback de compatibilitat per sign/html quan DocuSeal no accepta /submissions/html en determinades configuracions:
   - create template runtime via /templates/html
   - create submission via /submissions amb template_id
2. S ha estabilitzat la resolucio de source document_existing:
   - filtre per tenant_id
   - limit(1) + maybeSingle a la consulta d active_documents
3. La matriu executa primer els casos sign i després generate_only per evitar invalidar version_id PDF actual durant la mateixa execucio.
