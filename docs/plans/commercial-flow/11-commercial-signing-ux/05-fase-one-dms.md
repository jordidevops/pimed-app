# Fase 5 — Un sol document DMS i stamp fiable

> **Prerequisits:** fases 2–4  
> **Risc:** `sign-document-router` és compartit; canvi estrictament acotat a context comercial

## Objectiu

El PDF emès i el PDF firmat són versions del mateix `data.documents.id`. La fitxa comercial, el DMS i el justificant apunten al mateix historial.

## Problema actual

El comercial ja té `rendered_document_id`, però `sign_native` amb `source_type='document_existing'` pot executar `create_document_with_version` i crear una segona fila DMS. L'stamp després afegeix V2 només a aquesta còpia.

Resultat actual:

- «Obrir al DMS» i «Obrir PDF firmat» poden obrir documents diferents;
- preview comercial continua al PDF pre-firma;
- el fallback de camp de firma pot tapar l'EMISSOR.

## 5.1 Contracte de context

El router només activa el camí nou si rep context server-side verificable:

```text
commercial_decision_request_id
rendered_document_id
document_version_id
target_kind / target_id derivats de la request
```

No n'hi ha prou amb `source_type='document_existing'`: altres fluxos DMS podrien usar-lo.

Validacions:

- request tenant = document tenant;
- request snapshot apunta al mateix `rendered_document_id` i version;
- document no esborrat/protegit;
- version és la base fixada;
- provider intent actiu correspon a request.

## 5.2 Router natiu

En context comercial:

1. no cridar `create_document_with_version`;
2. crear submission/session sobre la version base;
3. conservar `source_document_id = rendered_document_id`;
4. stamp genera nova `document_versions` sota el mateix document;
5. `result_document_version_id` apunta a la nova versió;
6. hub/request projecten aquest resultat.

En context no comercial:

- comportament existent intacte;
- tests DMS genèrics obligatoris.

## 5.3 Camps de firma

Usar exclusivament:

- `<signature-field role="client_accept">` per quote/amendment;
- `<signature-field role="client_delivery">` per DN;
- `<signature-field role="client">` per agreement.

Regles:

- eliminar `client_reject` de plantilles noves;
- refús no estampa res;
- si falta el camp requerit: error `commercial_signature_field_missing`;
- prohibit fallback a coordenada genèrica/capçalera;
- si hi ha múltiples camps del mateix rol V1: error explícit, no triar-ne un arbitràriament.

Actualitzar:

- `platformCommercialHtml.ts`;
- plantilles platform seed ca/es/en;
- validadors de template;
- `stamp-pdf-signatures`;
- preview/field map si cal.

PDFs històrics ja emesos sense camp:

- no mutar-los;
- firma remota retorna error accionable;
- l'oficina pot generar una nova emissió/versió legal segons les regles existents, no re-render silenciós.

## 5.4 Preview i enllaços

Fitxa comercial:

- preview = versió base mentre open;
- preview = `result_document_version_id` quan accepted/signed;
- un sol CTA «Obrir al DMS»;
- «Veure justificant» separat del PDF comercial;
- historial DMS mostra V1 emesa, V2 firmada, audit si correspon.

No mostrar dos ids DMS per al mateix target nou.

## 5.5 Agreements

`commercial_agreement_versions.rendered_document_id` és el document canònic:

- `signed_document_id` no ha de crear una segona identitat; durant compatibilitat pot apuntar al mateix `document_id`;
- documentar/migrar semàntica abans d'eliminar cap columna;
- finalize usa result version del mateix document;
- annex quote manté hash/version exactes.

## Fitxers

- `supabase/functions/sign-document-router/index.ts`
- `supabase/functions/stamp-pdf-signatures/index.ts`
- shared native signing completion
- `apps/tenant-portal/src/features/commercial/templates/platformCommercialHtml.ts`
- `CommercialDocumentDetail.tsx`
- `CommercialDocumentView.tsx`
- `commercialDocumentModel.ts`
- agreement render/signing code

## Proves

1. Quote nativa: mateix `document_id`, V1 base + V2 firmada.
2. DN nativa: igual.
3. Agreement natiu: igual.
4. Refús: cap nova document version.
5. Camp absent: error; cap stamp a EMISSOR.
6. Dues signatures simultànies: només outcome guanyador queda canònic; versió òrfena, si es produeix, queda registrada per remediació i no projectada.
7. DMS genèric `document_existing`: comportament previ.
8. Preview comercial obre V2 després de firma.
9. Hub i request apunten al mateix result version.

## DoD

- [~] Cap flux comercial nou crea segon document DMS. *(codi; UAT 9xxx pendent)*
- [~] Stamp només sobre field semàntic. *(codi; UAT pendent)*
- [~] Preview mostra la versió firmada. *(codi; UAT pendent)*
- [~] Un CTA DMS. *(codi; UAT pendent)*
- [~] Agreements alineats. *(codi + revert send; UAT pendent)*
- [ ] Regressió DMS genèrica verda.

## Rollback

La branca està guardada per `commercial_decision_request_id`; es pot desactivar sense canviar el DMS genèric. No esborra versions ja creades.
