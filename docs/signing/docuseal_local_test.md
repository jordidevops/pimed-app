

## Pla de testing local amb DocuSeal + ngrok

### Arquitectura de les funcions rellevants

| Funció | `verify_jwt` | Qui la crida | Necessita ngrok? |
|---|---|---|---|
| [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0) | `true` | Frontend (amb JWT) | **NO** |
| [docuseal-webhook](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/docuseal-webhook:0:0-0:0) | `false` | DocuSeal (callback) | **SÍ** |

Ngrok **només** cal per exposar [docuseal-webhook](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/docuseal-webhook:0:0-0:0), perquè és DocuSeal qui ha de trucar-la.

---

## Pas 1: Generar `DOCUSEAL_WEBHOOK_SECRET`

```powershell
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Exemple de sortida: `a3f8c2d1e4b5a6f7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1`

Guarda-ho: anirà a **dos llocs** ([.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) + DocuSeal Dashboard).

---

## Pas 2: Omplir [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0)

Copia [.env.example](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.example:0:0-0:0) → [.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) i omple:

```bash
# supabase/functions/.env.local

EXT_SUPABASE_URL=http://localhost:54321

# Obtenir amb: supabase status --output env | grep SERVICE_ROLE_KEY
SERVICE_ROLE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

# De DocuSeal Dashboard → Settings → API → Test API key
DOCUSEAL_API_KEY=YOUR_DOCUSEAL_TEST_API_KEY

DOCUSEAL_API_URL=https://api.docuseal.eu

# El secret generat al Pas 1
DOCUSEAL_WEBHOOK_SECRET=a3f8c2d1e4b5...
```

> **Atenció `SERVICE_ROLE_KEY`**: usa `supabase status --output env` (format `eyJ...`), **no** `supabase status` que retorna el format `sb_secret_...` que no funciona a Edge Functions.

---

## Pas 3: Arrencar Supabase + Functions

```powershell
# Terminal 1: Supabase local (si no corre ja)
supabase start

# Terminal 2: Edge Functions amb les variables d'entorn
supabase functions serve --env-file supabase/functions/.env.local
```

Les funcions estaran a: `http://localhost:54321/functions/v1/`

---

## Pas 4: Exposar amb ngrok

```powershell
# Instal·lar ngrok si no el tens: https://ngrok.com/download
# o: choco install ngrok / winget install ngrok

ngrok http 54321
```

Ngrok et dona una URL pública tipus:
`https://abc123.ngrok-free.app`

La URL del webhook serà:
```
https://abc123.ngrok-free.app/functions/v1/docuseal-webhook
```

> **Problema del free tier**: la URL canvia cada cop que reinicies ngrok. Cada vegada cal actualitzar el webhook a DocuSeal Dashboard. Si vols URL estàtica → ngrok paid (`ngrok http --url=myapp.ngrok.app 54321`).

---

## Pas 5: Configurar DocuSeal Dashboard

1. Ves a **docuseal.eu** → login → utilitza el **Test Mode** (toggle a l'esquerra)
2. **Settings → API** → copia la Test API Key → posa-la a `DOCUSEAL_API_KEY`
3. **Settings → Webhooks** → Add Webhook:
   - **URL**: `https://abc123.ngrok-free.app/functions/v1/docuseal-webhook`
   - **Secret**: el valor de `DOCUSEAL_WEBHOOK_SECRET` del Pas 1
   - **Events**: selecciona almenys `submission.completed`, `form.viewed`, `form.completed`
4. Desa

---

## Pas 6: Verificar que tot connecta

Genera un token JWT local (usuari de test) i fes:

```powershell
# Prova sign-document-router (des del tenant-portal funciona automàticament)
# Per verificar que docuseal-webhook respon:
curl https://abc123.ngrok-free.app/functions/v1/docuseal-webhook `
  -X POST -H "Content-Type: application/json" -d "{}"
# Ha de retornar 400/401 (no 500) — indica que la funció respon
```

---

## Resum: on va cada variable

| Variable | [supabase/functions/.env.local](cci:7://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/.env.local:0:0-0:0) | DocuSeal Dashboard | Supabase Vault (staging/prod) |
|---|:---:|:---:|:---:|
| `DOCUSEAL_API_KEY` | ✅ | (font) | ✅ |
| `DOCUSEAL_API_URL` | ✅ | — | ✅ |
| `DOCUSEAL_WEBHOOK_SECRET` | ✅ | ✅ Webhook Secret | ✅ |
| `SERVICE_ROLE_KEY` | ✅ (format `eyJ...`) | — | (auto-inject) |
| `EXT_SUPABASE_URL` | ✅ | — | (no cal) |

---

## BYO (Bring Your Own) — estat actual

**Backend: implementat ✅**
- Taula `data.tenant_signing_config` amb `signing_mode` (`platform` / `byo`)
- RPC `api.save_tenant_docuseal_config` → desa la key al Vault
- RPC `api.get_docuseal_key_for_signing` → llegeix la key del Vault (SECURITY DEFINER)
- [sign-document-router](cci:9://file:///c:/JordiDevops/windsurf-app-supabase/supabase/functions/sign-document-router:0:0-0:0) ja bifurca entre mode `platform` i `byo`

**Frontend: pendent ❌**
- Pàgina de configuració per al tenant (on l'admin del tenant entra la seva API key de DocuSeal)
- Vista admin que mostra quins tenants fan servir `platform` vs `byo`

Per ara, tots els tenants funcionen en mode `platform` (utilitzen la `DOCUSEAL_API_KEY` global de l'entorn). El BYO és funcional a nivell de backend però sense UI per configurar-lo.