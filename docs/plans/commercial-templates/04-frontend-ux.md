# 04 — Frontend i experiència d'usuari

> **Pla:** [`README.md`](./README.md) · arquitectura [`02-rendering-architecture.md`](./02-rendering-architecture.md)

## 1. `/documents/templates` (QT-4)

- Afegir `quote` i `delivery_note` com a categories seleccionables al formulari de creació/clonació de plantilla (`useCreateTemplateMutation`, `useCloneTemplateMutation` a `apps/tenant-portal/src/features/signing/api/useDocumentTemplateMutations.ts` — **el mecanisme de clonació ja existeix i no cal tocar-lo**, només cal que la UI ofereixi aquestes categories i, si n'hi ha, les plantilles de plataforma filtrades per `target_archetypes` del tenant).
- Etiquetes i18n noves (Regla d'Or del repo, dos arguments sempre):
  - `t('templates.category.quote', 'Pressupost')`
  - `t('templates.category.delivery_note', 'Albarà')`
- Badge o indicador "Plantilla de cos complet" per distingir-les visualment de les de categoria `commercial` (header/footer), per evitar que un usuari pensi que pot combinar-les lliurement (són mútuament excloents, veure `02-rendering-architecture.md` §4).
- Previsualització: verificar que el motor de preview existent (basat en `sample_values`) funciona correctament amb el nou contracte de context (`lines[]`, `totals`), no només amb `context_refs` d'una única entitat com als usos actuals (RRHH/legal).

## 2. Selector de plantilla activa (nou, a Settings)

Seguint el patró de `permissions-settings` / `ConfigPage` ja usat al repositori:

- Nova secció (dins de la configuració comercial existent, si n'hi ha, o una de nova) perquè un `owner`/`manager` triï:
  - "Plantilla de pressupost activa" — entre les plantilles pròpies del tenant amb `category='quote'`.
  - "Plantilla d'albarà activa" — entre les pròpies amb `category='delivery_note'`.
- Escriu a `tenants.settings.commercial.quote_template_id` / `.delivery_note_template_id` (claus noves, paral·leles a `commercial.document_template_id` ja existent per al letterhead).
- Ha de deixar clar a la UI que, si n'hi ha una activa, **substitueix completament** el format actual (no es combina amb el letterhead de `commercial`).
- Permetre "Cap (usar format per defecte)" com a opció explícita per tornar al fallback.

## 3. Consideracions transversals

- Totes les strings noves amb `t('clau', 'Text per defecte en català')` — sense excepcions, seguint `copilot-instructions.md` de l'arrel.
- Regenerar `apps/tenant-portal/src/types/database.types.ts` i copiar-lo a `supabase/functions/_shared/database.types.ts` després de qualsevol migració d'aquest pla.
- No cal tocar `ProjectCommercialPanel` ni `CommercialDocumentView`: la crida a `render-commercial-document` no canvia de forma (mateix `document_id`/`client_op_id`), només canvia el que passa *dins* de l'edge function.
