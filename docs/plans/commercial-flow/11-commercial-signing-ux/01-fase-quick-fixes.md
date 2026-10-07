# Fase 1 — Correccions honestes i desacoblament de crèdits

> **Tall desplegable:** sí  
> **Schema:** cap  
> **Objectiu:** deixar de mentir a la UI abans de construir el domini nou

## Abast

1. Firma nativa disponible amb zero crèdits.
2. Draft sense «Reintentar PDF».
3. Refresh immediat després d'una acció local.
4. Badges de proveïdor/canal honestos.
5. Refús d'oficina de quote sense pad.
6. Compartir actual es presenta com **Només entregar**, no «enviar per acceptar».

## Implementació

### 1.1 Crèdits només per DocuSeal

Fitxers:

- `apps/tenant-portal/src/features/documents/pages/DocumentDetailPage.tsx`
- `apps/tenant-portal/src/features/documents/components/DocumentRow.tsx`
- `apps/tenant-portal/src/features/signing/components/DocumentOrchestrator.tsx`

Regles:

- no bloquejar l'entrada a l'orquestrador només perquè `signing_credits === 0`;
- `sign_native_presential` i `sign_native_remote` depenen de `native_signing_enabled`, no de crèdits;
- `sign_docuseal` depèn de provider actiu **i** crèdits > 0;
- copy: «DocuSeal no disponible: no hi ha crèdits» al provider, no banner global «Sense crèdits de signatura».

### 1.2 Draft i PDF

Fitxer:

- `apps/tenant-portal/src/features/commercial/components/CommercialDocumentShareSheet.tsx`

Regles:

- `status='draft'`: no cridar render ni oferir retry;
- copy: «Emet el document per poder-lo entregar o enviar per acceptar»;
- HTML/print de previsualització pot continuar si queda clar que és esborrany;
- un 409 `document_not_issued` no es mostra com error transitori.

### 1.3 Refresh local

Fitxers mínims:

- `QuoteDetailPage.tsx`
- `DeliveryNoteDetailPage.tsx`
- `AgreementsPage.tsx` / detall corresponent
- `CommercialDocumentDetail.tsx`

Després d'acceptar/refusar/firmar localment:

- invocar `onChanged`;
- invalidar document, llista i hub de firma;
- desactivar botons mentre la invalidació està en curs;
- no requerir reload de navegador.

El refresh d'una resposta **remota posterior** es resol a fases 2–4 (CS-D52).

### 1.4 Badges

Model derivat:

```text
provider: native -> Firma pròpia
provider: docuseal -> DocuSeal
signing_type: presential -> Presencial
signing_type: remote -> Remota
```

No usar «Firmat digitalment» com a únic badge comercial.

### 1.5 Refús d'oficina sense pad

- quote/amendment `issued`: confirmació + motiu obligatori → RPC existent de refús;
- no crear sessió, submission, DMS ni `client_reject`;
- copy: «Registra que el client ha refusat el pressupost fora de PiMed»;
- acord i albarà disputat no s'improvisen en aquesta fase: queden sense nou CTA de refús fins a fase 2.

### 1.6 Share sheet transitori

- acció actual = «Només entregar»;
- no afirmar que el client podrà acceptar/refusar l'adjunt;
- mantenir WhatsApp/correu/copiar/PDF sota aquest significat;
- la substitució per «Enviar per acceptar» arriba a fase 3.

## Locales

Actualitzar ca/es/en per:

- firma pròpia / DocuSeal;
- presencial / remota;
- només entregar;
- draft no signable;
- registrar refús extern.

## Proves

### Unit/Vitest

- zero crèdits + native enabled → acció nativa habilitada;
- zero crèdits + DocuSeal → provider deshabilitat;
- draft → no botó retry PDF;
- refús quote → no s'obre `SignaturePad`;
- badge provider i canal.

### Smoke navegador

1. Obrir quote draft seed 9xxx: copy correcte, cap retry.
2. Obrir quote issued: «Només entregar».
3. Amb 0 crèdits: firma pròpia remota/presencial disponible.
4. Refusar des d'oficina: estat actualitza sense reload i no es crea sessió de firma.

## DoD

- [x] Cap gate global de crèdits bloqueja nativa.
- [x] Draft no ofereix operacions impossibles.
- [x] Quote refusada per oficina sense pad.
- [x] Estat local coherent sense reload.
- [x] Share actual no es ven com a flux de decisió.
- [x] Tests afectats verds.

## Rollback

Canvis només UI/client. Revert dels fitxers de frontend; cap migració ni dada nova.
