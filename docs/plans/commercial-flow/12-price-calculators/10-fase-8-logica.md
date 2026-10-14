# Fase 8 — Editor de lògica

> **Tall desplegable:** sí
> **Schema:** cap. Només UI sobre l’AST de la fase 1.
> **Depèn de:** fases 1 i 4
> **Supòsit:** D5. No s’afegeix cap `op` nou.

## Què s’edita

Blocs llegibles, no una caixa de text:

- condició `when` amb comparacions (més enllà del booleà de la fase 4)
- `lookup_exact` i `lookup_tier`, triant taula i camp
- aritmètica amb blocs (sumar, restar, multiplicar, dividir, min, max, arrodonir)
- `if` amb dues branques
- línia nova buida (quantitat 1, preu constant, IVA 21 per defecte) que després es construeix amb blocs

Cada edició desa AST vàlid o no desa. El validador de la fase 1 és la porta. La previsualització i els casos es recalculen; un cas que abans passava pot passar a `fail`, i llavors la calculadora no es pot mantenir `active` fins a actualitzar el cas (mateixa regla de la fase 4).

## Fora, encara que l’usuari ho demani des de la UI

- Bucles i «una línia per element».
- Línies que llegeixen el total d’altres línies.
- Escriure una fórmula en text.
- Qualsevol op que no estigui a [`01-schema.md`](./01-schema.md). Això seria `schema_version` 2 i un altre pla.

## Verificació al navegador

- [ ] Partint de l’electricista, canviar el llindar de 30 km a 40 km amb el bloc del tram i veure el cas de 40 km passar a fail fins que s’actualitza l’esperat.
- [ ] Afegir una condició «només si la distància és més gran de 15» i veure que el cas de 20 km encara té desplaçament i el de 0 km no.
- [ ] Intentar enganxar text lliure no obre cap camp de fórmula.
- [ ] El JSON desat el torna a acceptar el validador de la fase 1 (test) i el motor dona el mateix hash que abans del canvi, si no s’ha tocat cap número.

## Acceptació

- [ ] Test: tot el que el constructor emet ja era un `Expr` vàlid a la fase 1 (rodona de fixtures).
- [ ] Recorregut de dalt al navegador, desktop i amplada mòbil del constructor (els blocs han de poder apilar-se).

## Fora

Importador Excel, noves operacions, IA (ja és a la fase 7; aquest editor només ha de poder obrir el que la IA hagi deixat).
