# Fase 6 — Formulari de paràmetres i flux ràpid

> **Tall desplegable:** sí
> **Schema:** cap, si la fase 2 ha deixat l’Edge
> **Depèn de:** fase 3 (defaults) i fase 4 (una calculadora `active`). La biblioteca (fase 5) no és prerequisit: n’hi ha prou amb una calculadora creada a l’editor.
> **Supòsits:** D1 (destí orfe), D2 (l’hàbit segueix al seu botó), D6, D7, D13

## Peça 1 — Formulari als dos composers

Al full de preus (`ProjectLinesSection`) i a l’orfe (`OrphanQuoteComposer`), una tercera acció al costat de «Servei habitual» i la línia manual: «Calculadora».

1. Llista només definicions `active` del tenant, amb un filtre opcional per tags (D16) quan n’hi ha moltes.
2. Formulari generat pels paràmetres: number, integer, money, boolean, enum (opcions de la taula `options_from`). Etiquetes amb D8.
3. Previsualització local amb el motor (línies + totals).
4. Confirmar crida `apply-calculator-run` amb el hash. Error `calculator_parity_mismatch` es mostra; no es deixa l’usuari amb línies a mitges.
5. Tornar a executar la mateixa calculadora substitueix només el seu grup (D13). Es pot fer des del grup de línies (acció «Tornar a calcular» que reobre el formulari amb els paràmetres del run).
6. Les línies generades es poden editar a mà després. En editar-ne una, `line_origin` passa a `manual` i es netegen `calculator_*` d’aquella fila, perquè un recàlcul no esborri el que l’usuari ha tocat. Les altres files del grup segueixen sent `calculator`.
7. Qui no té `commercial.pricing.edit` no veu l’acció. El servidor ja ho rebutja.

No s’afegeix la calculadora a `SaveAsHabitDialog`. No s’enganxen checklists.

## Peça 2 — Flux curt

Entrada: el mateix «Nou pressupost», amb una opció «Ràpid» a més d’orfe i prospecte, o un botó propi a `/sales/quotes`. No substituir els altres dos camins.

Passos, en aquest ordre:

1. Contacte (obligatori, com avui: `client_id` NOT NULL).
2. Font: un servei habitual **o** una calculadora activa. No les dues alhora en aquest flux.
3. Si la font és calculadora i hi ha paràmetres sense default, el formulari. Si tot té default, aquest pas no es mostra.
4. Emetre amb els defaults de la fase 3 (formalització i plantilla de pressupost). «Canviar» segueix disponible.
5. Destí: `create_orphan_quote_draft` → `apply-calculator-run` sobre el document → `issue_orphan_commercial_document`. No es crea OS.

Si la font és un hàbit: el diàleg de quantitats que ja té `ApplyPricingTemplateDialog`, escrivint al document pel camí que l’orfe ja usa (`onApplyLines` → `upsert_commercial_document_line`), i després emetre. No canviar el significat de l’hàbit.

Tres accions de l’usuari quan no cal formulari ni «Canviar»: contacte, font, emetre. El formulari de paràmetres és el quart pas només si falta alguna dada.

## Verificació al navegador

- [ ] Orfe esborrany: calculadora → paràmetres dels oracles → línies i total iguals que la previsualització de l’editor.
- [ ] Afegir una línia manual, tornar a calcular: la manual roman; les de la calculadora canvien.
- [ ] Editar a mà una línia generada, tornar a calcular: aquella fila roman; la resta del grup es substitueix.
- [ ] El mateix paràmetres al full de preus d’una OS: mateixos imports que a l’orfe (comparar net i IVA, no `total_with_tax` si D10 no ha alineat la vista).
- [ ] Flux ràpid amb defaults: contacte, calculadora, emetre. El document queda `issued`, orfe, amb `line_origin=calculator`, versió i run. No s’ha creat projecte.
- [ ] Sense defaults, el flux ràpid encara deixa «Canviar» / el pas de plantilla que la fase 3 conserva.
- [ ] Sense `commercial.pricing.edit`, l’acció no hi és.
- [ ] Amb diverses calculadores actives i tags assignats (D16), el filtre de tags redueix la llista del selector al full de preus, a l’orfe i al flux ràpid.
- [ ] Desktop i una amplada mòbil del formulari de paràmetres.

## Acceptació

- [ ] Test de paritat de destí: mateixos paràmetres, mateix hash de línies a projecte i a document (pot ser SQL + motor).
- [ ] Recorreguts de dalt al navegador, incloent l’estat buit (cap calculadora activa → l’acció explica que no n’hi ha cap d’activa, no un selector trencat).

## Fora

Crear OS prospecte des del flux curt, unificar hàbit i calculadora, editar la lògica.
