# 03 — Contracte d'UX

> **Pla:** [`README.md`](./README.md) · complementa el contracte mòbil de camp de [`../field-service/04-ux-contract.md`](../field-service/04-ux-contract.md)

## Principi

L'usuari de referència és un autònom amb el mòbil en una mà, en un replà o en una sala de calderes. Cada concepte que ha d'aprendre abans de cobrar és un motiu d'abandonament. Les obligacions legals s'han de complir **sense demanar-li que les entengui**: el sistema el guia.

## Estat actual i què s'hi ha de corregir

| Problema observat | Fitxer | Correcció |
|-------------------|--------|-----------|
| Falta `km` a les unitats, tot i que el seed «Desplaçament» ja el fa servir | [`ProjectLineForm.tsx`](../../../apps/tenant-portal/src/features/projects/components/ProjectLineForm.tsx), [`CatalogItemForm.tsx`](../../../apps/tenant-portal/src/features/catalog/components/CatalogItemForm.tsx) | Afegir `km` i preservar unitats no llistades |
| La taula de línies amaga quantitat, preu i descompte al mòbil | [`ProjectLinesSection.tsx`](../../../apps/tenant-portal/src/features/projects/components/ProjectLinesSection.tsx) | Targetes apilades amb els camps visibles |
| Formulari d'OS d'oficina: tipus, visibilitat, departament, local intern | [`ProjectForm.tsx`](../../../apps/tenant-portal/src/features/projects/components/ProjectForm.tsx) | Valors per defecte i camps avançats plegats |
| Cinc tabs horitzontals amb els imports al final | [`ProjectDetailPage.tsx`](../../../apps/tenant-portal/src/features/projects/components/ProjectDetailPage.tsx) | **Estabilitzat tècnicament:** un sol tablist Preparar / Fer / Entregar, URL canònica i CTA dins del flux; UAT humana pendent |
| El tancament requereix connexió i mèdia processada | [`CloseOutSheet.tsx`](../../../apps/tenant-portal/src/features/field-service/components/CloseOutSheet.tsx) | Tall 2: esborranys locals i emissió diferida |
| Materials només text lliure, sense catàleg ni preu | [`ProjectMaterialsSection.tsx`](../../../apps/tenant-portal/src/features/field-service/components/ProjectMaterialsSection.tsx) | Cerca de catàleg i recents |
| La fitxa de contacte ja té sis tabs | [`ContactDetailPage.tsx`](../../../apps/tenant-portal/src/features/contacts/components/ContactDetailPage.tsx) | **CF-14:** resum comercial a Contacte + tab «Pressupostos» (`?tab=quotes`) amb «Veure tots» |
| Cal trobar un pressupost sense obrir cada OS | — | **CF-15:** ruta `/quotes` al sidebar amb cerca (client, número, OS, text de línia), filtres, crear i duplicar |

## Acció principal única

A la pantalla de l'OS hi ha **una sola acció destacada**, que canvia segons la fase:

| Fase | Acció |
|------|-------|
| Sense autorització | Mostrar pressupost |
| Darrer pressupost refusat o caducat | Crear nou pressupost, amb confirmació i traça de substitució |
| Autoritzat, sense començar | Iniciar feina (**al strip de fitxatge**, no al dock) |
| Temps anterior, sense sessió oberta | Reprendre feina (**al strip de fitxatge**) |
| En curs | Revisar i tancar |
| Tancat sense albarà | Mostrar albarà |
| Albarà emès | Cobrar |
| Cobrat | Enviar comprovant |
| Tot fet (cobrat + comprovant ofert) | Sense dock; resum de l’expedient a Entregar |

El dock és `sticky` dins del flux en mòbil i compacte en escriptori; mai `fixed` sobre el contingut. La resta d'accions viuen al menú secundari.

### Fases visuals de l'OS (field service)

| Pas | Contingut |
|-----|-----------|
| **Preparar** | Full de preus (`project_lines`) + autorització (pressupost / renúncia) |
| **Fer** | Checklist, notes, materials/fotos, fitxatge |
| **Entregar** | Desviacions pendents; **Part de treball (butlletí), opcional**; **Albarà i cobrament**, independent del part; Expedient quan està complet |

`Activitat` surt de la barra cap al menú «Més». Les URL `?tab=budget|work|bulletin|punch|activity` es resolen com a àlies i es normalitzen a `?tab=prepare|do|deliver|activity`. La fase suggerida només governa la primera entrada: una selecció manual no es desfà quan canvia el workflow.

La progressió és monotònica segons la feina real, el part, l’albarà i el cobrament. Una autorització històrica inconsistent genera un avís consultable a l’historial, però no retorna una OS entregada a Preparar.

El Part de treball és un lliurable opcional: alguns tenants el publiquen al client i d’altres no. No publicar-lo no bloqueja l’albarà, el cobrament ni l’estat final de l’OS.

Per no carregar Entregar, un selector mostra **una sola vista cada vegada**: «Albarà i cobrament» per defecte o «Part de treball · Opcional». Els enllaços `?tab=bulletin` obren directament la vista del part.

El badge d’estat de l’OS (`Completat`, etc.) **no** barreja diners: el xip independent **«Pendent de cobrar»** indica saldo obert a la capçalera, al llistat i a Avui. La factura externa no es mostra al Tall 1.

## Happy path

Objectiu: crear l'OS en cinc tocs més el que s'hagi d'escriure.

1. **Nova feina** des d'Avui, Ordres o la fitxa del client.
2. Client: se salta si s'ha entrat des del client.
3. Adreça: automàtica si només n'hi ha una; es demana només si n'hi ha diverses, amb **Nova adreça** en línia.
4. **Visita estàndard** com a servei habitual.
5. Chips de km i hores previstes.
6. **Crear**.

Després:

- **Mostrar pressupost** obre el mode client a pantalla completa; **Acceptar** i **Refusar** amb el mateix pes visual, tal com exigeix la normativa.
- **Enviar** ofereix WhatsApp, compartició nativa, correu, enllaç i QR, sense dependre del portal ni de canals verificats.
- Si el client no vol pressupost: **Signar renúncia**, amb el text legal i la descripció de la feina.

Execució:

- temporitzador en un toc;
- km i materials des de la mateixa pantalla de feina;
- res d'això toca els imports comercials automàticament.

Tancament:

- **Revisar i tancar** atura el temporitzador i mostra **només les desviacions**: `2 h previstes → 2,5 h reals`, `15 km → 22 km`, materials afegits;
- si el total supera l'import autoritzat, la pantalla no deixa continuar cap a l'albarà i ofereix **Crear i acceptar ampliació** (si l’actor pot editar preus i l’overage és sota el llindar) o **Proposar ampliació** (emesa, `issued`, pendent d’aprovació);
- l’oficina revisa i accepta des d’Entregar (**Revisar / Acceptar**) quan cal;
- **Emetre albarà**, signar i **Cobrar** (bloquejat mentre hi hagi ampliació `issued`).

## Camins d'excepció

| Situació | Comportament |
|----------|--------------|
| Urgència sense pressupost | Renúncia signada amb descripció de la feina |
| Sobrecost detectat durant la feina | Ampliació abans de continuar |
| Sobrecost detectat en tancar | Ampliació amb data real d'acceptació; mai simular que va ser prèvia |
| Overage sobre el llindar o sense `commercial.pricing.edit` | Només proposar (`issued`); copy «Pendent d’aprovació» / «L’oficina ha d’aprovar abans de cobrar» |
| Overage sota el llindar amb permís de preus | Emetre i acceptar en el mateix pas (camí curt d’autònom) |
| Client refusa l'ampliació | L'albarà es limita a l'autoritzat; la diferència es registra amb motiu |
| Client B2B | Avís no bloquejant amb motiu |
| Sense connexió | Actuals i tancament en local; «Feina tancada · albarà pendent d'emetre» |
| L'enviament falla | El document continua emès; «Enviament fallit · Reintentar» |
| Sense correu del client | Compartició nativa, QR o WhatsApp immediats |
| Pressupost refusat o caducat | Badge terminal en lectura + «Crear nou pressupost» confirmat; el nou document enllaça l’anterior amb `supersedes_id` |
| Albarà signat incorrecte | Document de correcció amb traça, no mutació |
| Cobrament parcial | Suma de registres i saldo pendent |

## Chips de valors ràpids

Només per a **quantitats**:

- hores: 1 · 1,5 · 2 · 2,5 · 3 · 3,5 · 4 · 6 · 8
- km: 5 · 10 · 15 · 20 · 30 · 50
- visites: 1 · 2 · 3

Els **preus** no porten constants al codi: surten del catàleg, dels valors recents del tenant i de la tarifa. Posar 45 € o 60 € com a suggeriment universal ancoraria l'usuari a tarifes alienes i podria contradir el preu anunciat.

Els descomptes ràpids (0 · 5 · 10 · 15 · 20 %) només es mostren a qui té permís comercial.

## Rols i llindar (CF-13)

| Rol / capacitat | Pot |
|-----------------|-----|
| Autònom propietari (`owner`, llindar 0) | Tot el recorregut; emetre i acceptar ampliacions sense cerimònia |
| Oficina / manager (`commercial.pricing.edit`) | Canviar preu, descompte i IVA; acceptar ampliacions over-threshold |
| Tècnic (member sense pricing) | Quantitats i catàleg; **proposar** ampliació; **no** canviar preu ni acceptar over-threshold |
| Configuració | `commercial.deviation_approval_threshold_eur` (Més → Comercial); per defecte `0` |

Aquestes restriccions s'apliquen a RPC i RLS, no només amagant camps a React. Acceptar una `quote_amendment` amb overage per sobre del llindar sense `commercial.pricing.edit` retorna `office_approval_required`. Emetre un albarà amb ampliació `issued` retorna `pending_amendment_blocks_delivery`.

## Vocabulari a la interfície

- **Ordre de treball** de manera consistent; deixar d'alternar amb projecte, visita i OS.
- **Imports**, no «Valoració», que és llenguatge intern. A la UI de camp el tab es diu **Preparar** i la capa viva **Full de preus**.
- **Servei habitual** o **Pack**, no «Plantilla de valoració». Un servei pot portar checklists de visita vinculades (CF-23).
- **Part de treball** com a etiqueta principal del butlletí, útil sobretot en electricitat, on «butlletí» té un significat oficial diferent.
- **Esborrany** per a l'estat `draft` de l'OS.
- **Ampliació de pressupost**, no «extres» ni «suplement».
- Estat `issued` d’una ampliació → **Pendent d’aprovació** (no jargon tècnic).

## Accessibilitat i to

- Objectius tàctils grans i una sola columna al mòbil.
- No mostrar mai «cobrat» de manera optimista abans de la confirmació del servidor.
- Els missatges d'error han de dir què ha de fer l'usuari, no què ha fallat internament.
