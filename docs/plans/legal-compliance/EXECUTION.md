# Legal & Compliance — Pla mestre d’execució



> **Rol:** única font de veritat de l’ordre d’implementació i del treball pendent  

> **Creat:** 2026-08-15  

> **Pla d’arquitectura:** [`README.md`](./README.md)  

> **Estat per milestone:** [`STATUS.md`](./STATUS.md)  

> **Fase activa:** **LC-5** 📦 (opcional)  

> **Anterior:** LC-4 ✅



## Disciplina



1. Llegir aquest fitxer i STATUS a l’inici de cada conversa d’implementació.

2. Treballar **només** la fase activa (o un ítem de backlog acordat).

3. Al tancar: STATUS ✅ → changelog aquí → avançar fase activa.

4. No vendre DSAR parcial ni CMP inexistent com a “RGPD tancat”.



## Ordre (gates)



| Ordre | Fase | Nota |

|------:|------|------|

| 1 | **LC-0** | ✅ Docs + enllaços + inventari |

| 2 | **LC-1** | ✅ Legal Center + superfícies client/web |

| 3 | **LC-2** | ✅ Retenció + DSAR mínim customer-portal |

| 4 | **LC-3** | ✅ Empleat (footer/cookies/legal + stub PII) |

| 5 | **LC-4** | ✅ Recruitment unificat + DPA soft-duty |

| 6 | **LC-5** | 📦 CMP / gate termes si cal |



---



## LC-0 … LC-3 ✅



Veure STATUS / historial.



---



## LC-4 ✅ — Selecció + DPA (2026-08-15)



### Fet



1. Migració one-shot: `recruitment_settings.privacy_policy_url` → Legal Center `privacy_candidates` (`external_url`) si encara era plantilla (`00046`).

2. Recruitment Settings: camp URL substituït per enllaç a Legal; columna marcada DEPRECATED.

3. Soft-duty DPA: `dpa_acknowledged_at/by` + `acknowledge_my_tenant_platform_dpa` + banner a Legal (sense hard-block).

4. IA recruitment: checklist REC-8 intacte + hint a `dpa_platform`.

5. Careers rights: enllaç a política candidats via Legal Center.



### Fora d’abast



- E-sign / DocuSign de la DPA comercial.

- Hard-block de careers o butlletins per DPA no reconeguda.



---



## LC-5 📦 — CMP / gate termes



Només si s’afegeixen cookies no essencials a CP/PP. Mentrestant no cal implementar.



---



## Changelog



| Data | Canvi |

|------|--------|

| 2026-08-15 | LC-0 → LC-3 tancats seqüencialment |

| 2026-08-15 | LC-4 tancat (`00046` + UI); LC-5 opcional |

| 2026-08-15 | QA hardening (`00047` + URLs https + [`QA.md`](./QA.md)) |


