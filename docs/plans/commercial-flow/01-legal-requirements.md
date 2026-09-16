# 01 — Requisits legals de consum

> **Pla:** [`README.md`](./README.md)
> **Avís:** això no és assessorament jurídic. El detall varia per comunitat autònoma i per sector. Tot el que aquí es descriu ha de ser **configurable per tenant**, amb valors per defecte prudents.

## Per què condiciona el model de dades

Sense aquest capítol, el sistema natural seria: fer la feina, sumar el que s'ha consumit i cobrar-ho. Davant d'una persona consumidora **això no és vàlid**. La conseqüència és que l'aplicació ha de conèixer, en tot moment, **quant ha autoritzat el client**, i impedir emetre per sobre.

## Marc de referència

**Llei 22/2010, del 20 de juliol, del Codi de consum de Catalunya**, títol de les obligacions en la prestació de serveis:

1. Cal fer i lliurar **pressupost previ** del servei si el consumidor no en pot calcular directament el preu, **llevat que hi renunciï expressament, de manera manuscrita i amb la seva signatura**.
2. **L'import de la factura no pot ser superior al pressupostat**, si n'hi ha.
3. Si durant la prestació **apareixen conceptes nous** o altres modificacions, el prestador **ha de fer una ampliació o modificació del pressupost**, comunicar-la al consumidor i **aquest l'ha d'acceptar, de manera que en quedi constància**.
4. Els preus aplicats **no poden superar els anunciats** a la tarifa, sigui quin sigui el concepte.
5. Els pressupostos **no acceptats** només es poden cobrar si s'havia informat prèviament del cost i de l'import.

Règims sectorials més estrictes que cal preveure com a perfils del tenant:

- **Reparació de vehicles** (RD 1457/1986): pressupost previ obligatori, validesa mínima de 12 dies hàbils, modificació només amb autorització expressa i escrita.
- **Reparació d'aparells d'ús domèstic** (RD 289/2013): pressupost a disposició del consumidor, resguard de dipòsit, límit de l'import reparat.

## Contingut mínim del pressupost

El document ha de contenir com a mínim:

| Bloc | Detall |
|------|--------|
| Identificació | Prestador i consumidor, amb dades fiscals |
| Servei | Descripció de les operacions a fer |
| Desglossament | Mà d'obra, peces, recanvis, accessoris i despeses, per separat |
| Import | Total amb impostos inclosos |
| Terminis | Data prevista d'inici i durada |
| Validesa | Termini de validesa del pressupost |
| Dates i signatura | Data del pressupost i signatura del responsable |
| Resposta | Data d'acceptació **o de refús**, amb espais per signar **de mida igual** per a totes dues opcions |

El detall d'«espais de mida igual» té traducció directa a la UI: la pantalla d'acceptació **no pot fer més visible Acceptar que Refusar**.

Validesa per defecte al producte: **30 dies**, configurable, amb mínims sectorials.

## Renúncia al pressupost previ

Per a urgències i feines que el client vol resoldre al moment, la renúncia ha de:

- ser expressa, manuscrita i signada;
- anar acompanyada de la descripció de la feina autoritzada;
- quedar desada com a evidència, no com un simple `boolean`.

Si la descripció de la feina no s'ha omplert, la renúncia perd efecte. Això s'ha de validar abans de desar.

## Ampliació per sobrecostos

És el cas que motiva bona part del disseny:

1. Durant la feina apareix un concepte no previst.
2. El prestador **ha d'aturar-se, comunicar-ho i obtenir acceptació** amb constància.
3. Només llavors pot continuar i, després, cobrar-ho.

Traducció al producte:

- l'ampliació és un **document propi**, fill del pressupost;
- s'ha de poder crear i signar **des del mòbil, a casa del client**, sense passar per oficina;
- si s'accepta després d'executar, es registra amb la **data real** d'acceptació; el sistema no ha de simular que va ser prèvia;
- si el client la refusa, l'albarà **es limita a l'import autoritzat** i la diferència queda registrada com a no cobrable amb motiu.

## Retenció

Conservació mínima de sis mesos des de la no-acceptació o des de la fi del servei. El producte no fa esborrat físic de documents comercials; les baixes són lògiques i auditables.

## Llengua

Els documents adreçats a persones consumidores s'han de poder emetre **com a mínim en català**. El sistema ja té i18n `ca/es/en`; la plantilla del document ha de respectar la llengua del client i no la de l'usuari que l'emet.

## B2C contra B2B

Aquestes obligacions protegeixen la **persona consumidora**. Entre empreses preval la llibertat contractual.

Per tant el contacte necessita un indicador **`is_consumer`**:

| Situació | Comportament |
|----------|--------------|
| `is_consumer = true` | Bloqueig dur en emetre per sobre de l'autoritzat; renúncia o pressupost obligatoris abans de cobrar |
| `is_consumer = false` | Avís no bloquejant; es permet emetre amb registre del motiu |

El valor per defecte s'ha de derivar del tipus de contacte (persona contra empresa) i ha de ser editable.

## Recàrrecs

Els recàrrecs d'urgència, nocturnitat o festiu **no poden ser un increment improvisat**: han d'existir com a concepte publicat a la tarifa del tenant i entrar al document com a línia pròpia i identificable.

## Implicacions resumides per al disseny

| Requisit legal | Implicació tècnica |
|----------------|--------------------|
| Factura ≤ pressupost | `authorized_total` materialitzat i comprovat en emetre |
| Ampliació acceptada | `doc_type = 'quote_amendment'` amb `parent_document_id` i acceptació pròpia |
| Constància de l'acceptació | `commercial_document_events` amb signatura, data, canal i hash |
| Renúncia manuscrita | `quote_waivers` amb signatura i descripció de la feina |
| Contingut mínim | Snapshot complet al document; desglossament per línia |
| Acceptar i refusar equivalents | Contracte d'UI, no només de dades |
| Retenció | Sense esborrat físic |
| Preus ≤ anunciats | Els preus surten del catàleg i la tarifa, no de constants al codi |
