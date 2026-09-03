# Roadmap — fase C (planificat)

Funcionalitats **no implementades** encara. Documentades per alinear producte, tenants i desenvolupament.

---

## 1. Polítiques de dades per proveïdor (enterprise)

### Context

Avui el tenant és responsable de llegir i acceptar les polítiques de cada proveïdor (vegeu l'avís a `/settings/ai`). La fase C afegiria **controls configurables** a nivell plataforma i tenant.

### Objectius

- **Admin-portal**: definir per proveïdor quines dades es poden enviar (p.ex. bloquejar PII en prompts, exigir regió EU).
- **Tenant**: veure un resum de la política aplicable abans d'activar un proveïdor.
- **Auditoria**: registre de quin proveïdor/model va processar cada crida (ja parcialment al ledger d'ús).

### OpenRouter específic

OpenRouter ofereix [polítiques de dades i routing](https://openrouter.ai/docs/features/privacy-and-data-handling) per compte. La fase C podria:

- Passar paràmetres de privacitat a l'API (`provider` routing preferences) quan el tenant ho exigeixi.
- Mostrar enllaços directes a la configuració de privacitat del compte OpenRouter.

### Fora d'abast inicial

La plataforma **no** substitueix el DPA legal entre tenant i proveïdor. Els textos legals i contractes resten responsabilitat del tenant.

---

## 2. Routing i fallback entre models (OpenRouter)

### Context

OpenRouter pot enrutar a models alternatius si el principal no està disponible o per optimitzar cost/latència.

### Objectius

- Llista de **models de fallback** per tenant (ordre de prioritat).
- Reintent automàtic amb el següent model si la resposta és `model_not_found` o error de capacitat (avui només hi ha fallback dins del mateix proveïdor tenant sincronitzat).
- Opcional: límit de cost màxim per crida (OpenRouter suporta metadades de preu).

### Riscos

- Respostes inconsistents si el model de fallback és molt diferent.
- Cal registrar al ledger quin model va respondre realment.

---

## 3. Filtres de catàleg avançats

### Context

La fase B afegeix cerca per text. La fase C podria afegir:

- Filtre per **preu** / **context length** (metadades OpenRouter).
- Filtre per **modalitat** (només text, multimodal).
- **Llistes blanques** de models permesos per tenant (compliance).

---

## 4. Polítiques de retenció a la plataforma

### Objectius

- No persistir contingut de prompts/respostes als logs (avui el ledger guarda metadades d'ús, no el text).
- TTL configurable per errors de verificació de clau (`key_last_error`).
- Export / esborrat de dades d'ús IA per tenant (RGPD).

---

## 5. Integració amb contractes i consentiment

### Objectius

- Checkbox de conformitat a `/settings/ai` («Confirmo haver revisat les polítiques del proveïdor») amb data i usuari.
- Versió de la política de plataforma mostrada al tenant quan activa IA.

---

## Priorització suggerida

| Ordre | Item | Impacte |
|-------|------|---------|
| 1 | Consentiment explícit tenant (5) | Baix esforç, clarifica responsabilitat |
| 2 | Llistes blanques de models (3) | Compliance |
| 3 | Routing/fallback OpenRouter (2) | Fiabilitat |
| 4 | Polítiques de dades API (1) | Enterprise |
| 5 | Retenció i RGPD (4) | Legal / ops |

---

## Estat actual (fases A + B)

| Funcionalitat | Estat |
|---------------|-------|
| BYOK 4 proveïdors | ✅ |
| Sync catàleg models | ✅ |
| Models suggerits (admin) | ✅ |
| Cerca al selector | ✅ |
| Avís responsabilitat dades (UI) | ✅ |
| Polítiques API per proveïdor | ⏳ Fase C |
| Routing/fallback OpenRouter | ⏳ Fase C |
| Consentiment formal | ⏳ Fase C |
