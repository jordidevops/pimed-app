# PDF / Gotenberg — ajuda ràpida

- **Gotenberg local (URLs, fonts, CHROMIUM_ALLOW_LIST):** veure [gotenberg-local.md](./gotenberg-local.md)
- **Admin PDF settings:** deixa `http://localhost:3007` — no posis `host.docker.internal`
- **Edge Functions:** `GOTENBERG_URL=http://host.docker.internal:3007` a `supabase/functions/.env.local`

# Cua de pdfs

A l'esquema pgmq tenim la taula q_document_pdf_queue amb el pdfs a processar per la funció process-document-pdf-queue.

PGMQ no retorna totes les files de q_document_pdf_queue. Només retorna missatges visibles (vt <= now()). Quan el worker llegeix un missatge i falla, PGMQ el marca invisible durant el visibility timeout (abans 180s, ara 60s) i retryWithBackoff pot allargar-lo encara més (fins a 1h).

-- Fer visible immediatament (ex: msg_id 34)
SELECT pgmq.set_vt('document_pdf_queue', 34, 0);

-- Comprovar estat
SELECT msg_id, read_ct, vt, vt <= now() AS visible,
       message->'payload'->>'job_id' AS job_id
FROM pgmq.q_document_pdf_queue;

# E2E Fase 1 — Submission Hub (firma pròpia)

Després d'una firma presencial/remota amb plantilla «Test de firmes»:

```powershell
cd scripts
$s = supabase status -o json | ConvertFrom-Json
$env:SUPABASE_SERVICE_ROLE_KEY = $s.SERVICE_ROLE_KEY
$env:SUPABASE_URL = $s.API_URL
node test-phase1-native-signing-hub.mjs
# Opcional: $env:SUBMISSION_ID = "<uuid>"
```

Comprova: `signing_provider=native`, sessions, events, `completed`, hashes via RPC.

# Fase 4 — Signatures a etiquetes + mode evidències

- **Config:** Admin → PDF → «Mode d'evidències» (`detached` per defecte: PDF net + auditoria separada).
- **Plantilla:** «Test de firmes» (`…000015`) amb `<signature-field role="worker|manager">`.
- **Flux:** `sign_native` injecta marques `[[SIG:role]]` → Gotenberg → `signing_field_map` a sessions → `stamp-pdf-signatures` overlay a coordenades.
- **Pressupost/albarà:** camí `document_existing` sobre el PDF ja renderitzat. L'estampat detecta `[FIRMA:role]` en viu. Si el PDF té `[FIRMA:` i el rol del signant no es resol → `signature_field_not_found` (no peu). Sense token (fallback QT-D1) → peu. Gate 2026-09-18: `detectFieldForRole(client_accept)` sobre HTML comercial via Gotenberg local `:3007`.
- **`audit_trail_storage_path`:** l'omple el job Edge `process-audit-pdf-queue`; no es verifica amb un `DO $$`. Comprovar a mà o via job local.
- Després de canvis a Edge Functions: `supabase functions serve` (o reiniciar el servei local).

# Fase 3 — Centre de signatures (integritat)

Al detall d'una submission **firma pròpia** (`/documents/signing/:id`):

- Secció **Integritat del document**: hashes SHA-256 per signant + comprovació de fitxer (PDF del sistema o pujat).
- RPC: `get_signature_audit_for_submission(submission_id)`.
- En procés seqüencial (`in_progress`), el PDF firmat parcial és visible abans que tothom signi (migració `20260615000011`).