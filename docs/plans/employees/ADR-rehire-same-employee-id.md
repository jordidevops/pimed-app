# ADR — Rehire: mateix `employee_id` vs nou registre

**Estat:** Acceptat (ES-2)  
**Data:** 2026-07-20  
**Context:** transició `terminated → onboarding` amb `reason_code = rehire`

## Decisió

Al MVP-ELM, un **rehire reutilitza el mateix `employee_id`**.

La transició seedada `terminated → onboarding` (`rehire`) deixa l'historial de lifecycle, certificacions i events al mateix registre. No es crea un empleat nou automàticament.

## Per què

- Preserva ledger de compliment i cicle de vida (auditoria contínua).
- Evita duplicar mappings externs / portal tokens / qualificacions sense una eina de fusió.
- El contracte nou (EC, post-MVP) pot apuntar al mateix empleat amb un període nou.

## Alternatives rebutjades (per ara)

| Opció | Motiu de diferiment |
|---|---|
| Nou `employee_id` + enllaç `previous_employee_id` | Requereix model de fusió i migració de certificacions; post-MVP |
| Soft-delete + clonar | Duplica historial i complica Readiness |

## Conseqüències

- `document_id` / email poden actualitzar-se a l'empleat existent abans o durant el rehire.
- UI ha de deixar clar que el rehire continua el mateix expedient.
- Si un tenant necessita un expedient net (p.ex. litigis), es fa manualment creant un empleat nou **sense** passar per `rehire` (fora del flux assistit).
