# IA — documentació d'ajuda

Índex de guies sobre la configuració i l'ús de la IA al tenant-portal.

| Document | Contingut |
|----------|-----------|
| [BYOK — guia operativa](../ia-byok.md) | Configuració de claus, límits, membres, resolució de problemes |
| [Proveïdors i models](./proveidors-i-models.md) | OpenAI, Anthropic, Gemini, OpenRouter; selecció i sincronització de models |
| [Roadmap fase C](./roadmap-fase-c.md) | Funcionalitats planificades (polítiques de dades avançades, routing, etc.) |

## Abast de la IA a l'aplicació

La IA no es limita a plantilles documentals. Les mateixes claus i configuració alimenten:

- Wizard de contingut d'idioma per plantilles
- Accions «Generar amb IA» integrades a altres pantalles
- Futures eines (resums, classificació, assistents, etc.)

Cada tenant tria el **proveïdor per defecte**, el **model** i els **paràmetres de generació** per proveïdor a `/settings/ai`.

## Responsabilitat del tenant

La plataforma **no** processa les dades amb models propis: actua com a intermediari que envia les peticions al proveïdor BYOK del tenant. Consulteu la secció *Polítiques de dades* a `/settings/ai` i el document [Roadmap fase C](./roadmap-fase-c.md) per a obligacions i millores previstes.

## Referències tècniques

- Pla d'arquitectura: `docs/plans/ai/tenant_byok_enterprise_v2.md`
- Codi UI: `apps/tenant-portal/src/features/ai/`
- Edge Functions: `save-tenant-api-key`, `generate-ai-content`, `refresh-ai-models`
