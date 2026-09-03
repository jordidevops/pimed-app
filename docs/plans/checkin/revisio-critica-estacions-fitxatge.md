# Revisió crítica — Pla d'estacions de fitxatge

> **Tipus:** snapshot d'auditoria; no és un roadmap viu  
> **Data:** 2026-07-15  
> **Origen:** revisió crítica del pla, l'estudi UX, el codi i les migracions  
> **Plans afectats:** [`plan-attendance-stations.md`](./plan-attendance-stations.md), [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md)  
> **Execució i estat de resolució:** [`EXECUTION.md`](./EXECUTION.md)

## Veredicte

L'MVP és funcional, però «implementat» no equival a «apte per producció». Els tres blockers conceptuals són:

1. suplantació en mode manual;
2. accés a historial amb autenticació insuficient;
3. confusió entre lloc de fitxatge, lloc planificat i lloc realment treballat.

Les correccions d'aquesta revisió no s'han de gestionar des d'aquest document. Cada finding té correspondència al pla mestre d'execució.

## Findings

| ID | Severitat | Àrea | Problema | Correcció exigida |
|---|---|---|---|---|
| RC-01 | Crític | Model | ST-6c presenta la ubicació del punch d'entrada com a lloc treballat | Separar `punch_location_id`, `scheduled_location_id` i `worked_location_id`; reanomenar informes que només coneixen el primer |
| RC-02 | Crític | Privacitat | Historial de fins a 90 dies accessible amb DNI + confirmació nominal | Historial desactivat per defecte; PIN o credencial equivalent sempre obligatori per consultar-lo |
| RC-03 | Crític | Pla | ST-18 es tractava com a UX opcional malgrat la suplantació coneguda | ST-18a és gate de producció si s'habilita llista/document; fins llavors QR-only o risc explícit |
| RC-04 | Crític | Seguretat | `source=qr` és falsificable perquè el punch no exigeix token | Resolve i punch atòmics, o reserva/token recent vinculat a dispositiu, empleat i operació |
| RC-05 | Crític | Seguretat | El QR es consumeix abans que l'usuari confirmi el punch | Consum dins la transacció del punch o reserva temporal segura |
| RC-06 | Alt | Offline | Retard legítim i rellotge manipulat són indistinguibles | Àncora temporal servidor + monotònic, edat màxima i quarantena |
| RC-07 | Alt | Offline | ST-9 V2 només entrega punches diferits; no permet identificació offline | Anomenar-lo `deferred punch delivery`; credencials cachejades només si es dissenya offline real |
| RC-08 | Alt | Privacitat | DNI/sufix permet enumerar personal | Respostes genèriques, rate limit, auditoria, emmascarament i PIN abans de dades personals |
| RC-09 | Alt | Seguretat | `device_secret` en `localStorage` és exfiltrable per XSS | Cookie HttpOnly/SameSite via proxy, CSP/origen aïllat, rotació i revocació |
| RC-10 | Alt | Implementació | `Europe/Madrid` hardcoded en fluxos d'estació | Timezone del site a totes les RPC, inclosos nocturns i dates d'assignació |
| RC-11 | Alt | Model | ST-19 no garanteix integritat tenant/site ni preservació històrica | Validacions, snapshots publicats, política de delete i revalidació en publish/swap |
| RC-12 | Alt | Pla | El post-MVP es presentava com a opcional, inclosos gates | Separar Production Gates, Product Enhancements i Demand-only |
| RC-13 | Alt | Pla | ST-11 estava desactualitzat: resolve ja tenia rate limit | Tancar resolve; obrir rate limit d'emissió QR, mètriques i lockout |
| RC-14 | Alt | Pla | «Sense GPS» contradiu ST-5 | Documentar que no es desa geo al punch, però ST-5 pot fer una lectura puntual |
| RC-15 | Mitjà | Model | `source` barreja canal i mètode d'identitat | `channel`, `identity_method` i `sync_mode` separats |
| RC-16 | Mitjà | API | Errors d'assignació poden acabar com 500 | Contracte estable 403/409 i proves E2E |
| RC-17 | Mitjà | Pla | Ordre de fases incorrecte | Gates → ST-18 core/18a/18b → ST-19 → ST-18c → offline |
| RC-18 | Mitjà | Docs | Pla principal manté text històric contradictori | Pla principal = estat/roadmap; estudi = especificació; eliminar duplicats |

## Canvis de model imprescindibles

### Ubicació

```text
punch_location_id     on s'ha registrat el punch
scheduled_location_id on estava planificat treballar
worked_location_id    on consta que s'ha prestat el treball, si es pot acreditar
```

No es pot inferir `worked_location_id` només de la tablet utilitzada.

### Identitat

El DNI és un identificador, no una contrasenya. El mode ràpid per fitxar no pot reduir el nivell d'autenticació necessari per consultar historial.

### Temps offline

Una diferència gran entre `occurred_at` i `received_at` pot ser una cua legítima. Cal conservar ambdós instants i quantificar la confiança temporal.

### Configuració

Cal oferir presets segurs —per exemple `estricte`, `ràpid supervisat`, `qr`— i validar combinacions. Una llista de booleans independents permet estats insegurs o incoherents.

## Roadmap corregit derivat de la revisió

1. **Gate de producció:** rate limits, CI, contracte d'errors, timezone per site, protecció del secret i QR vinculat al punch.
2. **Identitat i privacitat:** ST-18 core/18a, historial amb PIN, lookup anti-enumeració i separació de canals.
3. **Planificació espacial:** ST-19 amb integritat, snapshots i semàntica d'ubicacions.
4. **Offline fiable:** ST-9 V2 amb àncora temporal, idempotència, quarantena i `max_age`.

## Innovacions que encaixen

| ID | Funcionalitat | Valor |
|---|---|---|
| IN-01 | Autenticació adaptativa | Exigir PIN en historial, ubicació incorrecta, sufix curt o intents repetits |
| IN-02 | Cobertura viva per ubicació | Comparar torns publicats amb presència real i proposar substitució |
| IN-03 | Àncora temporal offline | Beacon servidor + rellotge monotònic per reconstruir l'instant |
| IN-04 | Codi d'empleat privat | Identificador kiosk rotatori separat del DNI |
| IN-05 | Fleet management | Heartbeat, config versionada, rollout, lockdown i rotació de secrets |
| IN-06 | Explicabilitat d'anomalies | Mostrar causa i permetre sol·licitar correcció |
| IN-07 | Override d'emergència auditat | Codi manager d'un sol ús, motiu obligatori i caducitat |
| IN-08 | Privacitat kiosk | Noms emmascarats, sense avatar, auto-blank i reautenticació |

## Anti-idees

- biometria al kiosk;
- GPS continu d'una estació fixa;
- cache offline de tota la plantilla amb DNI;
- IA que registra punches automàticament;
- bloqueig dur per ubicació planificada com a default.

## Traçabilitat

La resolució de `RC-*` i la promoció de `IN-*` es controla exclusivament a [`EXECUTION.md`](./EXECUTION.md). Aquest snapshot no s'ha de reescriure per marcar findings com a resolts.
