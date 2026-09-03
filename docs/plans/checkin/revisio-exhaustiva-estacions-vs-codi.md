# Revisió exhaustiva: pla + estudi vs codi/migracions

> **Tipus:** snapshot d'auditoria tècnica; no és un roadmap viu  
> **Data:** 2026-07-15  
> **Abast revisat:** migracions ST-1…ST-14, `station-api`, UI `/station`, portal empleat i schema de torns  
> **Execució i estat de resolució:** [`EXECUTION.md`](./EXECUTION.md)

## Resum executiu

L'MVP ST-1…ST-8 + ST-2a/6b/6c està implementat i és coherent en aparellament, snapshots, assignacions, QR one-shot i timestamp servidor online. Els plans post-MVP descriuen bé la direcció, però barregen tres estats diferents:

- implementat;
- disseny funcional tancat;
- implementació pendent.

Els riscos principals són suplantació al kiosk, QR desvinculat del punch, offline encara incompatible amb les decisions documentades i abast de ST-19 subestimat.

## Findings crítics

| ID | Finding verificat | Evidència principal | Acció |
|---|---|---|---|
| RX-C1 | Selecció manual permet punch sense verificació | `apps/public-portal/app/station/page.tsx` | ST-18/18a gate o QR-only |
| RX-C2 | `source: "qr"` es pot enviar sense token | `supabase/functions/station-api/index.ts` | Token obligatori i vinculat al punch |
| RX-C3 | QR queda consumit durant resolve | migració `20261014000007_attendance_identity_tokens_st4.sql` | Consum atòmic en punch o reserva |
| RX-C4 | ST-9 V2 es documenta com decidit però SQL força `now()` | migració `20261014000001_attendance_stations_st1.sql` | `p_offline_sync`, `p_occurred_at`, skew i `OFFLINE_DELAY` |
| RX-C5 | UI no persisteix `client_op_id` | `lib/attendance-station/client.ts` | Outbox IndexedDB amb ID estable |
| RX-C6 | «Sense GPS» contradiu lectura one-shot ST-5 | `deviceGeo.ts`, `station/page.tsx` | Corregir semàntica documental |

## Findings alts

| ID | Finding verificat | Acció |
|---|---|---|
| RX-A1 | Resolve QR no valida elegibilitat de zona igual que el punch | Compartir validació o retornar warning/pin requirement coherent |
| RX-A2 | ST-11/decisió #12 desactualitzats | Resolve rate limit = fet; emissió QR = pendent |
| RX-A3 | `verify-employee-pin` proposat no existeix i el PIN portal usa `token_id` | Challenge curt específic d'estació amb lockout |
| RX-A4 | `punch_only_at_stations` ST-10 no existeix | Implementar abans de reorganitzar QR/botó portal |
| RX-A5 | Helpers de document només fan match complet | RPC d'estació per `full/suffix`, normalització i anti-enumeració |
| RX-A6 | ST-19 afecta més que schema + UI | RPCs, vistes, integritat, publish, swaps, push, snapshots i recompute |
| RX-A7 | Lookup DNI/sufix facilita enumeració | Rate limit dispositiu+IP, respostes uniformes, logs sense document |

## Findings mitjans

| ID | Finding verificat | Acció |
|---|---|---|
| RX-M1 | No existeix màquina d'estats de sessió ST-18 | Implementar `waiting → identity → employee_session → closing` |
| RX-M2 | Idle actual 90 s vs default proposat 60 s | Config a `attendance_devices`, sense magic numbers |
| RX-M3 | QR continua sobre el botó de punch del portal | ✅ EX-02.5 — `/portal/station-qr` |
| RX-M4 | Fallback d'assignacions fixes pot confondre lloc del dia | Només avís informatiu, mai substitut del slot |
| RX-M5 | Assignacions tenen dates al schema però no a la UI | ST-2a+ amb `starts_on/ends_on` |
| RX-M6 | `OFFLINE_DELAY` està documentat però no existeix | Afegir anomaly en sync diferit |
| RX-M7 | Endpoints ST-18 ignoren helpers existents | Reutilitzar `compute_employee_punch_day_state` |
| RX-M8 | Cap camp ST-18/ST-19 proposat existeix encara | Migracions ordenades, no marcar com implementat |
| RX-M9 | No existeix snapshot/anomalia de punch fora d'assignació | `anomaly_codes` o camp snapshot |
| RX-M10 | Pla encara conté «quan s'implementi» amb MVP fet | Separar estat actual de roadmap |

## Findings baixos/documentals

| ID | Finding verificat | Acció |
|---|---|---|
| RX-B1 | Decisions duplicades i salt #25 | Una sola taula de decisions |
| RX-B2 | Ordre de fases divergent entre pla i estudi | Adoptar un únic ordre al pla mestre |
| RX-B3 | Estudi diu «QR → punch directe», codi fa dos passos | Corregir descripció |
| RX-B4 | ST-6c només agrega al client | No presentar-lo com a informe legal |
| RX-B5 | Secret a `localStorage` | Promoure protecció a gate de producció |

## Alineacions confirmades

| Àrea | Estat verificat |
|---|---|
| Aparellament per codi tenant | Implementat ST-1b |
| Timestamp online servidor | Implementat |
| Snapshots d'ubicació i noms | Implementat ST-3 |
| Assignacions amb herència pare | Implementat ST-2a |
| QR signat one-shot amb TTL | Implementat ST-4, però desvinculat del punch |
| PIN kiosk per accions admin | Implementat ST-2b |
| Diagnòstic ST-19 sense `location_id` | Correcte |
| Proxy `identity/qr-token` | Corregit |
| Eliminació de `shared_device` | Implementada |

## Abast real de ST-19

ST-19 no és un `ALTER TABLE` aïllat. Ha d'incloure:

- `work_shifts.default_location_id`;
- `shift_slots.location_id` i snapshots;
- coherència tenant/site/location;
- vista `api.shift_slots`;
- `assign_shift_slot`;
- publicació i revisions;
- swaps i claims;
- push;
- recompute de jornades afectades;
- consulta portal/estació;
- proves nocturnes i timezone.

La definició autoritativa ampliada és [`plan-shift-planner-v2.md`](./plan-shift-planner-v2.md).

## Offline: diferència entre decisió i implementació

Perquè ST-9 V2 sigui real:

1. generar `client_op_id` abans de desar l'operació;
2. congelar l'instant del toc;
3. conservar `received_at`;
4. validar àncora temporal i skew;
5. marcar `OFFLINE_DELAY`;
6. sincronitzar idempotentment;
7. quarantena després de retries o confiança insuficient;
8. no activar el flag de producció fins passar E2E de pèrdua/retorn de xarxa.

Identificar l'empleat offline és un problema separat i queda fora del primer abast.

## Ordre derivat de l'auditoria

```text
Gates de producció i QR atòmic
  → ST-10 + ST-18 core/18a/18b
  → SP-0/SP-1 + ST-19
  → ST-18c/18d
  → ST-9 V2
  → cobertura, vacants i automatitzacions
```

## Traçabilitat

Els IDs `RX-*` es mapen a paquets executables a [`EXECUTION.md`](./EXECUTION.md). Aquest document conserva el diagnòstic original encara que el codi posterior el resolgui.
