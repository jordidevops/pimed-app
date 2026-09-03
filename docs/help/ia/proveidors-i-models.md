# Proveïdors i models

Guia per triar i mantenir models a `/settings/ai` i als selectors de cada acció d'IA.

---

## Proveïdors suportats

| Proveïdor | Clau BYOK | Models típics | Notes |
|-----------|-----------|---------------|-------|
| **OpenAI** | `sk-...` | `gpt-4o-mini`, `gpt-4o` | API directa OpenAI |
| **Anthropic** | `sk-ant-...` | `claude-3-5-haiku-latest`, `claude-sonnet-4` | API directa Anthropic |
| **Google Gemini** | clau Google AI | `gemini-2.0-flash`, `gemini-2.5-flash` | API Google Generative Language |
| **OpenRouter** | `sk-or-v1-...` | `openai/gpt-4o-mini`, `anthropic/claude-sonnet-4`, … | Una clau, centenars de models via [OpenRouter](https://openrouter.ai/) |

Els quatre proveïdors **convíuen**: un tenant pot tenir claus de tots i triar el per defecte.

---

## Models suggerits vs catàleg complet

### Suggerits (plataforma)

L'admin-portal defineix `suggested_models` per proveïdor a `platform_ai_defaults`. El tenant els veu al grup **Suggerits** del selector, sense haver sincronitzat encara.

Són recomanacions generals (velocitat, cost, qualitat) per a **qualsevol ús** de la IA a l'app: textos, plantilles, resums, classificació, etc.

### Sincronitzats (tenant)

El botó **Actualitzar models** crida l'API del proveïdor amb la clau BYOK i desa `available_models` al tenant. Per OpenRouter el catàleg pot superar centenars d'entrades.

### Cerca (fase B)

Quan hi ha més de 12 models, apareix un camp **Cerca model...** que filtra la llista. Els suggerits es mostren en un grup separat.

---

## OpenRouter

### Format d'ID

Els models OpenRouter usen `proveïdor/model`, per exemple:

- `openai/gpt-4o-mini`
- `anthropic/claude-sonnet-4`
- `google/gemini-2.5-flash`

### Flux recomanat

1. Desa la clau `sk-or-v1-...` i verifica.
2. Revisa els models **Suggerits** (curats des d'admin).
3. Opcional: **Actualitzar models** per carregar el catàleg complet.
4. Usa la cerca si la llista és llarga.
5. Pots escriure manualment un ID si no apareix a la llista (camp de text quan encara no hi ha catàleg).

### Override per acció

Al popover d'engranatge (wizard, `AIGenerateAction`) pots canviar proveïdor/model **només per aquella crida** sense modificar la configuració del tenant.

---

## Paràmetres de generació

Per cada proveïdor, a `/settings/ai`:

| Paràmetre | Efecte |
|-----------|--------|
| **Prompt de sistema** | Instruccions permanents abans de cada conversa |
| **Temperatura** | 0 = més previsible; 1 = més variació |
| **Màx. tokens** | Límit de longitud de la resposta |

Per defecte s'hereten dels valors de plataforma (admin). El tenant pot personalitzar-los o **restablir als valors de plataforma**.

---

## Enllaços útils

- [OpenRouter — models](https://openrouter.ai/models)
- [OpenRouter — crèdits](https://openrouter.ai/settings/credits)
- [OpenAI — API keys](https://platform.openai.com/api-keys)
- [Anthropic — console](https://console.anthropic.com/)
- [Google AI Studio](https://aistudio.google.com/)
