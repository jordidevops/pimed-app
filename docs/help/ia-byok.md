# IA amb clau pròpia (BYOK)

Guia per configurar i usar la generació amb IA al tenant-portal: claus per proveïdor, límits d'ús, polítiques per membre i wizard de plantilles.

---

## 1. Visió general

El sistema suporta **Bring Your Own Key (BYOK)**: cada tenant aporta les seves claus API d'OpenAI, Anthropic, Google Gemini o **OpenRouter**. La plataforma:

- **Verifica** la clau abans de desar-la (crida mínima al proveïdor).
- **Emmagatzema** la clau de forma segura a Vault (mai al navegador ni a la base de dades en text pla).
- **Medeia** totes les crides des de les Edge Functions (el frontend no accedeix mai a la clau).
- **Registra** l'ús intern (crides, tokens, bloquejos) per gràfics i límits.

| Proveïdor | Ús típic |
|-----------|----------|
| **OpenAI** | GPT-4o, GPT-4o-mini |
| **Anthropic** | Claude 3.5 Haiku / Sonnet |
| **Google Gemini** | Gemini 2.0 / 2.5 Flash |
| **OpenRouter** | Accés unificat a molts models (`proveïdor/model`) |

Documentació ampliada: [docs/help/ia/](./ia/README.md) (models, cerca, roadmap fase C).

---

## 2. Configuració (`/settings/ai`)

Només **propietaris** i **gestors** poden configurar claus. La pàgina té tres pestanyes:

### Configuració

Per cada proveïdor:

1. Introdueix la **API key** (camp password).
2. Tria el **model per defecte** (o selecciona'l de la llista després de sincronitzar models).
3. Opcional: **Base URL** si uses un proxy o endpoint compatible.
4. Clica **Verificar i desar** — la clau es prova contra el proveïdor abans de guardar-se.
5. **Actualitzar models** — sincronitza el catàleg de models disponibles amb la teva clau.

Enllaç **Gestiona facturació** → et porta al panell del proveïdor (consum i facturació són responsabilitat teva, no de la plataforma).

**Proveïdor per defecte**: el servei que usarà el wizard de plantilles, les accions «Generar amb IA» i la resta d'eines d'IA de l'aplicació.

### Polítiques de dades

A la part superior de la pàgina hi ha un avís sobre **responsabilitat del tenant**: les dades enviades a la IA es processen pel proveïdor BYOK configurat. Cal revisar les polítiques de privacitat i retenció de cada proveïdor. Vegeu [roadmap fase C](./ia/roadmap-fase-c.md) per a millores planificades.

### Ús i límits

- KPIs dels últims 30 dies (crides, tokens, bloquejades).
- Barres de progrés del límit horari i diari.
- Desglossament per proveïdor i top usuaris.

### Membres (només propietari)

Defineix per cada membre:

| Política | Efecte |
|----------|--------|
| **Permetre** | Ús normal amb els límits del tenant (o personalitzats). |
| **Avís** | Pot generar, però veu un banner d'avís persistent. |
| **Bloquejar** | Totes les crides retornen error `user_blocked`. |

Opcional: **límit/h** i **límit/dia** personalitzats per usuari (sobreescriuen els del tenant).

---

## 3. Generar contingut

### Wizard de plantilles

Al crear o editar un idioma de plantilla:

1. Obre el **wizard IA** i configura el cas d'ús.
2. Clica **Executar IA i importar** (crida `generate-ai-content` amb la teva clau BYOK).
3. Revisa el JSON importat i continua a la vista prèvia.

Si no hi ha clau verificada, el botó estarà deshabilitat amb enllaç a `/settings/ai`.

### Component reutilitzable

Altres pantalles poden usar `AIGenerateAction`:

- Botó **Generar amb IA**
- Engranatge per override temporal de model / temperature / max tokens (no es desa)

---

## 4. Límits i avisos

Ordre d'aplicació:

1. Política d'usuari (`block` → atura immediatament).
2. Límits personalitzats de l'usuari (si n'hi ha).
3. Límits del tenant (hora / dia).
4. Avisos al **80%** del límit diari (configurable).

Quan es supera el límit amb bloqueig actiu → HTTP **429** i registre `blocked_rate_limit` al ledger.

---

## 5. Seguretat

- Les claus **mai** es retornen al client després de desar-les.
- `get_ai_api_key_for_generation` només és accessible per **service_role** (Edge Functions).
- La verificació de clau és **obligatòria** abans de persistir.
- Els membres amb rol `block` no poden generar encara que coneguessin l'endpoint.

---

## 6. Addon `addon_ai` (hub/spoke)

Si el teu pla inclou l'addon **Generació amb IA (BYOK)**:

- Activar l'addon posa `tenant_ai_config.is_active = true`.
- Desactivar-lo revoca l'accés (`is_active = false`) sense esborrar les claus configurades.

---

## 7. Resolució de problemes

| Símptoma | Acció |
|----------|-------|
| «Configuració AI incompleta» | Verifica que el proveïdor per defecte tingui clau **verificada**. |
| «Model not found» | Clica **Actualitzar models** o canvia el model a un de la llista. |
| «Has superat el límit» | Revisa Ús i límits; el propietari pot ajustar polítiques o límits. |
| «L'accés està bloquejat» | El propietari t'ha marcat com a `block` a la pestanya Membres. |
| Verificació falla (422) | Revisa la clau, permisos del compte i Base URL si n'uses una de custom. |

---

## 8. Referències tècniques

- Pla d'arquitectura: `docs/plans/ai/tenant_byok_enterprise_v2.md`
- Edge Functions: `save-tenant-api-key`, `generate-ai-content`, `refresh-ai-models`
- Codi UI: `apps/tenant-portal/src/features/ai/`
