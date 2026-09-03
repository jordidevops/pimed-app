# Anàlisi de producte — Control horari, portal, estacions, ubicacions i torns

> **Tipus:** snapshot d'anàlisi i oportunitats; no és un roadmap viu  
> **Data:** 2026-07-15 · **Actualitzat:** 2026-07-20 (AP-06 backlog; estats AP-* revisats)  
> **Execució i prioritat vigent:** [`EXECUTION.md`](./EXECUTION.md)
## Estat sintetitzat en la data de revisió

| Àmbit | Diagnòstic |
|---|---|
| Pipeline legal | Madur: raw → intervals → resums → tancament/export |
| Calendari laboral | Avançat, amb cascada d'overrides, festius i grups |
| Fitxatge personal | Disponible amb pauses, geo configurable i offline |
| Portal empleat | Avançat: token/PIN, Identity Gate, push i confirmació |
| Estacions | MVP local implementat; no apte per producció compartida sense gates |
| Ubicacions | Jerarquia i assignacions disponibles; semàntica de lloc treballat incompleta |
| Planificador | Backend inicial disponible; UI i integració amb horari efectiu incompletes |
| Offline robust | Backend batch disponible; clients i kiosk encara divergents |
| Automatitzacions | Deteccions existents, motor no connectat de punta a punta |
| Integracions | Export parcial; import/mapping ERP-nòmina pendents |

## Principis de producte

- raw immutable i correccions auditades;
- calendari legal, planificació operativa i presència real són capes diferents;
- tenant-portal, portal empleat i kiosk són superfícies diferents;
- ubicació organitzativa, ubicació planificada, ubicació del punch i GPS no són sinònims;
- tokens i decisions sensibles són server-authoritative;
- PiMed és font fiable d'hores, no un motor complet de nòmina.

## Oportunitats prioritzades

| ID | Proposta | Valor | Esforç | Dependències | Estat |
|---|---|---:|---:|---|---|
| AP-01 | Ubicació al planificador i resolver canònic | Molt alt | M–L | SP-0/SP-1 | (veure pla V2) |
| AP-02 | Política només-estació + identitat/privacitat kiosk | Alt | M | Gates, ST-10, ST-18a | ✅ EX-02 / ST-10 |
| AP-03 | Batch offline unificat al client | Alt | S–M | Idempotència i contracte batch | ✅ EX-05.1 |
| AP-04 | Cobertura operativa planificada vs real | Alt | M | ST-19, resolver, demanda | ✅ EX-06 |
| AP-05 | Dashboard de cua i salut d'estacions | Alt | S–M | ST-12, observabilitat |
| AP-06 | Check-in contextual | Alt | M | ST-19 ✅, Work Status ✅ | **📦 Backlog** — sense especificació d'implementació |
| AP-07 | Offline kiosk honest i limitat | Alt | M | ST-18, batch, àncora | ✅ EX-05 |
| AP-08 | Automatitzacions d'anomalies | Alt | M | NotificationService | ✅ EX-08.2 (+ Fase 6) |
| AP-09 | Risc operatiu heurístic, sense ML | Mitjà | S–M | Cobertura i dades | ✅ EX-08.3 |
| AP-10 | Fleet management multiestació | Mitjà-alt | M | ST-12 | ✅ AP-05/10 |
| AP-11 | Accessibilitat i privacitat UX | Mitjà-alt | S–M | ST-18 | ✅ EX-02 (esp. 02.7) |
| AP-12 | Pont CSV/API a ERP i nòmina | Alt | M–L | Mapping extern i export | ⚠️ CSV ✅; EI3+ Holded/PayFit en cua |

## Detall de les apostes principals

### AP-01 — Planificació integrada

Unir calendari, `work_schedules`, torns publicats, absències, ubicació i fitxatges mitjançant un resolver únic. És prerequisit de recordatoris, estació contextual, cobertura i nòmina coherent.

Especificació: [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md).

### AP-02 — Kiosk segur sense biometria

- `punch_only_at_stations`;
- document-first o QR;
- sessió d'empleat;
- PIN per historial i accions de risc;
- countdown i tancament explícit;
- lookup anti-enumeració.

Especificació: [`estudi-station-punch-ux-v2.md`](./estudi-station-punch-ux-v2.md).

### AP-04 — Cobertura operativa

Comparar, per franja, ubicació i rol:

```text
demanda
  vs torns publicats
  vs absències
  vs presència real
```

El resultat ha de permetre actuar: crear vacant, reassignar o avisar. Un recompte diari no detecta una punta de servei.

### AP-06 — Check-in contextual

**Estat:** 📦 **backlog de producte** (2026-07-20). Dependències tècniques satisfetes; **no** hi ha pla d'implementació ni paquet EX assignat.

**Què és:** unificar a la UX de fitxatge (portal i/o estació) el context de *què toca ara* — torn/ubicació esperada (ST-19), estat de jornada vs horari (Work Status), i CTA d'acció (entrada / pausa / sortida) — en lloc de botons genèrics desconnectats del pla del dia.

**Bases ja disponibles (no cal reimplementar-les):**

- ST-19 / EX-03.4 — `scheduled_location_*` al resolver i ubicació als `shift_slots`;
- Work Status Fase A — `computeWorkScheduleStatus` + targetes in-app;
- Work Status Fase B — recordatoris push (canal separat);
- ST-18c — avis d'ubicació planificada vs estació (warn/block).

**Què faltaria si es vol fer:**

1. **Especificació d'implementació** (pla curt): superfícies (estació / portal / tots dos), wireframes o fluxos, criteris d'acceptació i rollback.
2. Assignació a un paquet a [`EXECUTION.md`](./EXECUTION.md) i decisió explícita de prioritat.
3. Implementació que **reutilitzi** resolver + Work Status (sense nova font de veritat).

**Decisió:** es deixa en backlog fins que hi hagi demanda de producte / client. No bloqueja el roadmap EX tancat.

### AP-05/AP-10 — Operar un parc d'estacions

**Estat:** ✅ (2026-07-18) — migració `20261052000001`

- heartbeat i `last_seen_at` ✅ (EX-01.6) + telemetry outbox al heartbeat ✅;
- versió de configuració (`config_version`) ✅;
- dispositius pendents/suspesos (filtres + status_counts) ✅;
- rotació de secrets (bulk revoke) ✅;
- rollout/lockdown (`ops_lockdown` + bulk) ✅;
- cua i errors de sync (pending/quarantine reportats pel kiosk) ✅;
- alertes per divergència o estació morta (panell flota + widget Tauler) ✅.

### AP-08 — Automatitzacions inicials

Primers triggers recomanats:

- `PAUSE_NOT_CLOSED`;
- `PUNCH_OUT_MISSING`;
- `OVERTIME_THRESHOLD_EXCEEDED`;
- `SHIFT_COVERAGE_GAP`.

Començar in-app, amb deduplicació i quiet hours. No introduir canals externs fins tenir lliurament observable.

### AP-09 — Heurístiques explicables

Ús acceptable:

- patrons d'absència per franja/dia;
- risc de gap demà;
- suggeriments de reforç;
- alertes de retard recurrent agregades.

No usar scoring opac per sancionar, ordenar o excloure empleats.

### AP-12 — Integracions

Ordre recomanat:

1. import CSV d'empleats;
2. `external_entity_mappings`;
3. codis d'export;
4. Holded inbound pilot;
5. PayFit BYO API;
6. webhook de període tancat.

## Funcionalitats innovadores realistes

1. Planificació i presència viva per ubicació.
2. Autenticació adaptativa segons risc de l'acció.
3. Codi privat d'empleat separat del DNI.
4. Àncora temporal offline.
5. Explicabilitat d'anomalies i sol·licitud de correcció.
6. Override d'emergència auditat.
7. Vacants i substitucions basades en elegibilitat.
8. Forecast assistit per reserves, vendes o producció, només com a proposta.

## Anti-idees

- biometria facial/empremta com a resposta al problema d'identitat;
- geofencing bloquejant per defecte;
- QR no signat;
- ML d'absentisme amb impacte sobre persones;
- app nativa separada abans de completar PWA;
- prometre background sync garantit a iOS;
- edició offline de calendaris/torns/absències;
- replicar un motor de nòmina;
- administrar estacions només des del dispositiu;
- gamificació/rankings de puntualitat;
- mapa continu de tots els empleats;
- drag-and-drop avançat abans de tancar la semàntica;
- cache offline de tota la plantilla;
- integració INSS automàtica sense API fiable;
- unificar portal tokenitzat i compte tenant per defecte.

## Criteri de promoció

Cap oportunitat `AP-*` passa a implementació perquè aparegui en aquest document. Ha de:

1. estar assignada a un paquet de [`EXECUTION.md`](./EXECUTION.md);
2. tenir dependències satisfetes;
3. disposar de criteris d'acceptació i rollback;
4. no introduir una font de veritat paral·lela.
