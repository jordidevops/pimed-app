# Fase 4 — Editor de taules i paràmetres, i prova de casos

> **Tall desplegable:** sí
> **Schema:** cap taula nova si la fase 2 està feta. RPC de desar esborrany, publicar, activar, arxivar i desar casos, si no s’han creat totes a la fase 2.
> **Depèn de:** fase 2
> **Supòsits:** D7, D8, D11, D12

## Què s’edita en aquesta fase

Primera capa, només:

- nom i descripció de la calculadora
- paràmetres: clau, tipus, etiqueta (idioma actiu), min/max, obligatori, valor per defecte, unitat, `options_from` si és enum
- constants de tarifa (`hour_eur` i similars): valor o buit
- files de taules: columnes ja declarades a la definició, cel·les numèriques o buides, etiqueta de fila
- línies: nom, unitat, `kind` (`product` | `service`), `allow_zero_price`, i un interruptor `when` limitat a **sempre** / **mai** / **si un paràmetre booleà és cert**
- previsualització: l’usuari posa valors d’exemple i veu línies, nets, IVA i total amb `previewTotals`

La lògica arbitrària (AST que no sigui const, lookup o el `when` simple) es mostra en només lectura, amb un avís «aquesta part no s’edita aquí». No hi ha caixa de fórmules. Això és la fase 8.

## Estats

| Estat | Quan | Es pot executar? |
|-------|------|------------------|
| draft | acabat de crear, encara no s’ha intentat activar | no |
| incomplete | forats null, `assumed: true`, o cap cas verd | no |
| active | portes de [`01-schema.md`](./01-schema.md) § Activació | sí |
| archived | l’usuari l’arxiva | no |

Publicar congela versió. Activar exigeix versió publicada + cas verd + cap forat. Desar un canvi de tarifa sobre una calculadora `active` crea esborrany nou (`draft`/`incomplete`) i no toca la versió publicada ni els pressupostos ja emesos. Cal tornar a publicar i a passar el cas.

## Casos

L’usuari desa almenys un cas: paràmetres + línies esperades. El botó «Comprovar» executa el motor i marca `pass` o `fail` amb el diff (quantitat, preu, nom, línia de més o de menys). No es pot activar amb `unrun` o `fail`.

El primer cop, «Usar la previsualització com a resultat esperat» copia la sortida actual al cas. A partir d’aquí el cas és la xarxa: si la tarifa canvia, el cas falla fins que l’usuari l’actualitzi a consciència.

## Fitxers

- Ruta nova sota configuració o catàleg, al costat de les plantilles de preu. Punt de partida de navegació: el mateix grup que `CatalogPacksPage` / `PricingTemplateForm` (`apps/tenant-portal/src/features/catalog/`). No barrejar el formulari de l’hàbit amb aquest.
- Components nous: llista, editor de taules, formulari de paràmetres de previsualització, llista de casos.
- Servei: RPCs a `commercialFlowService.ts` (o un `calculatorService.ts` al mateix feature si el fitxer ja és gran).
- Locales ca/es/en.
- Permís de UI: amagar l’editor si el rol no és owner/manager (D7). El servidor torna a comprovar-ho.

## Verificació al navegador

- [ ] Crear una calculadora, deixar `hour_eur` buit, intentar activar: bloqueig amb motiu visible.
- [ ] Omplir la tarifa, previsualitzar l’electricista de fixture (0 km, 20 km, 40 km) i veure els imports dels oracles.
- [ ] Desar el cas des de la previsualització, activar, veure l’estat activa.
- [ ] Canviar la tarifa: l’estat deixa d’estar actiu per a la versió nova; un pressupost que ja s’hagués aplicat a la fase 2 (o un run de prova) conserva els imports vells.
- [ ] Arxivar la treu del selector d’execució (el selector arriba a la fase 6; aquí n’hi ha prou que `list` d’actives no la retorni).
- [ ] Vista estreta: la taula de tarifes es pot editar sense perdre columnes fora de pantalla (scroll o fitxa).

## Acceptació

- [ ] Tests del validador d’activació: null, `assumed`, cas fail, cas pass.
- [ ] Publicar dues vegades crea `version_number` 1 i 2. La 1 no es pot actualitzar (test SQL de la fase 2, repetit si la RPC de publicar és nova).
- [ ] Recorregut de dalt al navegador.

## Fora

Constructor de lookups i aritmètica (fase 8), IA (fase 7), biblioteca (fase 5), flux curt (fase 6).
