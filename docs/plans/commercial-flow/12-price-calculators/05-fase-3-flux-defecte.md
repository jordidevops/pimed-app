# Fase 3 — Flux per defecte del tenant

> **Tall desplegable:** sí. Independent del motor; es pot fer en paral·lel amb les fases 0–2.
> **Schema:** cap (les claus ja existeixen)
> **Depèn de:** res de CF-29
> **Supòsits:** cap de D1–D14, excepte no inventar `preferred_entry`

## Què hi ha

`data.tenants.settings.commercial`:

- `formalization_mode_default` (`signed_quote` | `separate_agreement`)
- `quote_template_id` (o el sentinella `"none"` que ja resol `data.resolve_commercial_full_body_template_id`)
- `agreement_template_id`

UI d’edició: `apps/tenant-portal/src/features/commercial/components/CommercialDocumentTemplatesSection.tsx`, només owner/manager. Parsers: `deviationApprovalThreshold.ts`.

El wizard no els llegeix.

## Abast

1. En obrir `CreateQuoteWizardDialog`, si `formalization_mode_default` és vàlid, no mostrar el pas de formalització: usar el default i seguir cap a orfe o prospecte. El pas de tipus (orfe vs prospecte) es manté.
2. Un control «Canviar» en aquest pas, o al resum del diàleg fill, reobre el selector actual de formalització només per aquell document.
3. A `PrepareQuoteWizard` (camí C) i a l’emissió de l’orfe (`OrphanQuoteComposer` / `issue_orphan_commercial_document`), si `quote_template_id` està definit, no mostrar el pas de plantilla i passar `p_full_body_template_id` amb aquest id. «Canviar» reobre `DocumentTemplateSelect` (`AgreementTemplateSelect.tsx`).
4. A `PrepareAgreementDialog`, si `agreement_template_id` està definit, preseleccionar-lo i no obligar a tornar-lo a triar. Avui ja cau al default si existeix; comprovar-ho i, si el diàleg encara força una decisió redundant, saltar-la amb el mateix «Canviar».
5. Sense cap default, el comportament d’avui es conserva (el wizard pregunta).
6. No afegir claus noves. No implementar `preferred_entry`.
7. Locales ca/es/en amb `t('clau', 'Fallback català')` per a «Canviar» i el resum «S’usarà la plantilla per defecte».

## Fitxers

- `apps/tenant-portal/src/features/commercial/components/CreateQuoteWizardDialog.tsx`
- `PrepareQuoteWizard.tsx`
- `OrphanQuoteComposer.tsx` (el punt on es tria plantilla i formalització abans d’emetre)
- `PrepareAgreementDialog.tsx`
- `apps/tenant-portal/src/features/commercial/utils/deviationApprovalThreshold.ts` (reutilitzar parsers; no duplicar-los)
- locales `projects` ca/es/en

## Verificació al navegador

Amb un tenant owner que tingui els tres defaults desats a Configuració → Plantilles:

- [ ] Nou pressupost → orfe: no apareix la tria de formalització. El document queda amb aquest mode.
- [ ] Nou pressupost → prospecte: igual, i Preparar no torna a demanar plantilla. L’emissió persisteix `full_body_template_id` i `formalization_mode`.
- [ ] «Canviar» permet un altre mode i una altra plantilla només en aquell document. El setting del tenant no canvia.
- [ ] Preparar acord usa la plantilla d’acord per defecte sense un pas obligatori extra.
- [ ] Treure els defaults (o provar un tenant sense) torna a mostrar els passos d’avui.
- [ ] Un rol que no és owner/manager no veu l’editor de settings (ja és així). El flux d’emissió sí que llegeix els defaults.

## Acceptació

- [ ] Test unitari del helper que decideix «saltar o preguntar» a partir del JSON de settings, incloent `"none"`, valor invàlid i clau absent.
- [ ] Els recorreguts de dalt, fets al navegador, no només una captura.

## Fora

Calculadora, tria orfe vs prospecte automàtica, permisos nous.
