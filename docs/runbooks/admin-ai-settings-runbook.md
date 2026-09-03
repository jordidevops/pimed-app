# Runbook — Admin AI Settings (`/dashboard/settings/ai`)

Guia operativa de la pantalla d'admin AI del portal (`http://localhost:3000/dashboard/settings/ai`) per entendre:

- què configura cada secció,
- com impacta runtime i base de dades,
- i com executar canvis en producció amb risc controlat.

> En producció, substitueix `http://localhost:3000` pel domini real del `admin-portal`.

---

## 1) Qui hi té accés

- **Lectura**: rols `admin` i `support`.
- **Escriptura**: només rol `admin` per canvis sensibles (claus API, defaults globals, capacitats de model).

Autorització implementada a Server Actions (`assertAdmin`) i RPCs/Edge Functions backend.

---

## 2) Què configura aquesta pantalla

La pàgina té dues àrees principals:

1. **Configuració global per proveïdor** (OpenAI, Anthropic, Gemini, OpenRouter)
2. **AI Model Capabilities** (registre tècnic de capacitats per model)

### 2.1 Configuració global per proveïdor

Per cada proveïdor pots gestionar:

- **Platform API Key**
  - Accions: verificar i desar, eliminar, refrescar models.
  - Efecte:
    - Desa clau xifrada a Vault (no queda en clar a DB).
    - Marca proveïdor com verificat.
    - Permet sincronitzar `/models` del proveïdor.

- **Base URL**
  - Útil per endpoints personalitzats/proxy compatibles.
  - Efecte sobre verificació i sync de models.

- **Suggested models**
  - Llista de recomanacions que veuen els tenants al portal client.
  - No força selecció, però orienta UX.

- **Default model**
  - Model preferit de plataforma per proveïdor.
  - Serveix de fallback per tenants sense override.

- **Billing URL**
  - Enllaç informatiu al tenant-portal.

- **System prompt / temperature / max tokens**
  - Defaults de generació de plataforma.
  - Els tenants poden heretar-los o sobreescriure'ls.

### 2.2 AI Model Capabilities

Registre tècnic per model (`provider + model_id`) amb camps com:

- `vision`
- `tools`
- `tools_with_vision`
- `streaming`
- `max_image_size_mb`
- `supported_image_mimes`
- `max_file_size_mb`
- `supported_file_mimes`
- `context_window`
- `needs_review`
- `deprecated`
- `source`

Aquest registre és el que usa el backend per validar comportaments multimodals (imatges/PDF/tools/streaming) i exposar metadata de suport.

---

## 3) Impacte de cada acció (mapa funcional)

## `Verificar i desar clau`
- Backend:
  - Server Action: `savePlatformApiKey(...)`
  - Edge Function: `save-platform-api-key`
- Efecte:
  - verifica clau contra API del proveïdor;
  - desa secret xifrat;
  - intenta sync inicial de models.
- Risc:
  - clau incorrecta -> error de verificació;
  - sense clau vàlida no hi ha sync.

## `Llegir models de l'API`
- Backend:
  - Server Action: `refreshPlatformProviderModels(...)`
  - Edge Function: `refresh-platform-ai-models`
- Efecte:
  - consulta `/models`;
  - actualitza `available_models` del proveïdor;
  - **models nous detectats** es registren automàticament a `ai_model_capabilities` amb `needs_review = true`.

## `Desar` (defaults globals del proveïdor)
- Backend:
  - Server Action: `upsertPlatformAiDefault(...)`
  - RPC: `upsert_platform_ai_defaults`
- Efecte:
  - actualitza defaults globals visibles/consumits pels tenants.

## `Desar` fila a AI Model Capabilities
- Backend:
  - Server Action: `upsertAiModelCapabilityAdmin(...)`
  - RPC: `upsert_ai_model_capability_admin`
- Efecte:
  - crea/edita capacitats del model;
  - pot marcar `needs_review=false` quan validació ja està feta;
  - pot deprecar (`deprecated=true`) models obsolets.

---

## 4) Flux recomanat en producció

## 4.1 Alta o canvi de clau d'un proveïdor

1. Introduir clau i `Base URL` (si aplica).
2. Clicar **Verificar i desar clau**.
3. Clicar **Llegir models de l'API**.
4. Revisar la secció **AI Model Capabilities** filtrant per proveïdor i `needs_review`.
5. Validar models nous i ajustar camps de capacitat.
6. Treure `needs_review` dels models aprovats.

## 4.2 Govern de models nous (important)

Després de cada sync, qualsevol model nou queda en `needs_review=true`.

Política recomanada:
- **No habilitar massivament** models nous sense revisió.
- Revisar mínim:
  - suport real de vision/tools/streaming,
  - límits de fitxer/imatge,
  - compatibilitat de context window,
  - cost/rendiment esperat.

## 4.3 Canvi de defaults (prompt/temperature/tokens/model)

1. Aplicar canvi a un sol proveïdor.
2. Validar generació amb un tenant intern de prova.
3. Monitoritzar errors/latència.
4. Si correcte, mantenir; si no, rollback immediat als valors previs.

---

## 5) Checklist previ a canvis en producció

- Confirmar rol `admin`.
- Tenir **valor actual** copiat abans de modificar (prompt, tokens, model, mimes, flags).
- Fer canvi en franja de baixa activitat.
- Comunicar a l'equip si afecta model per defecte o prompt global.

---

## 6) Smoke test ràpid després de canvis

## 6.1 UI
- La targeta del proveïdor ha de mostrar estat coherent (`Clau verificada` si aplica).
- El botó `Llegir models de l'API` ha de completar sense error.
- A AI Model Capabilities, els models nous han d'aparèixer amb `needs_review`.

## 6.2 Backend (opcions)
- Confirmar que hi ha models a `available_models`.
- Confirmar que models nous entren a `ai_model_capabilities`.
- Confirmar que `needs_review` es pot canviar i persistir.

---

## 7) Rollback (si un canvi trenca comportament)

## Cas A — problema de qualitat/cost de generació
- Revertir `default_model`, `temperature`, `max_tokens`, `system_prompt` al valor anterior.

## Cas B — problema de capacitats multimodals
- A `AI Model Capabilities`:
  - desactivar flags afectats (`vision`, `tools`, etc.),
  - o marcar model com `deprecated`.

## Cas C — clau/API inestable
- Tornar a clau prèvia (si disponible) o eliminar clau temporalment.

---

## 8) Notes operatives

- `needs_review` és el mecanisme de govern principal per nous models detectats via sync.
- `source` ajuda a traçar origen (`platform_sync`, `tenant_sync`, `admin`, etc.).
- Si es fan canvis massius de capacitats, fer-los per lots petits i validar entre lots.

---

## 9) Fitxers clau relacionats

- UI pàgina: `apps/admin-portal/app/dashboard/settings/ai/page.tsx`
- UI defaults: `apps/admin-portal/components/dashboard/settings/AdminAiSettings.tsx`
- UI capabilities: `apps/admin-portal/components/dashboard/settings/AdminAiModelCapabilities.tsx`
- Server actions: `apps/admin-portal/app/admin/actions/ai-settings.ts`
- Migració admin+sync: `supabase/migrations/20260620153441_ai_model_capabilities_admin_and_sync.sql`

