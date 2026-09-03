# Legal & Compliance — Estat d’implementació



> **Última actualització:** 2026-08-15  

> **Propòsit:** seguir el desenvolupament del mòdul Legal Center / RGPD de plataforma.  

> **Pla:** [`README.md`](./README.md) · ordre [`EXECUTION.md`](./EXECUTION.md) · [`GLOSSARY.md`](./GLOSSARY.md)



## Llegenda



| Símbol | Significat |

|--------|------------|

| ✅ | Fet i usable |

| 🔄 | En curs |

| ❌ | No començat |

| 📦 | Diferit |

| ⚠️ | Parcial |



**Proves manuals:** [`QA.md`](./QA.md)



---



## Milestones



| Fase | Nom | Estat | Notes |

|------|-----|-------|-------|

| **LC-0** | Contracte i documentació | ✅ | |

| **LC-1** | Legal Center + superfícies client/web | ✅ | QA: URLs https + sense `dpa_platform` públic |

| **LC-2** | Retenció + DSAR mínim CP | ✅ | QA: staff report-scoped + `retention_status` (`00047`) |

| **LC-3** | Empleat + portal empleat | ✅ | Stub PII; EHR-3.4 diferit |

| **LC-4** | Selecció + DPA comercial | ✅ | `privacy_candidates` canònic + DPA soft-duty |

| **LC-5** | CMP / gate termes opcional | 📦 | Només si calen cookies no essencials |



---



## LC-4 — Selecció + DPA



| # | Ítem | Estat | Evidència |

|---|------|-------|-----------|

| 1 | Una sola font `privacy_candidates` | ✅ | Careers ja resolien LC; migrate URL legacy → external_url (`00046`) |

| 2 | UI recruitment sense editar URL legacy | ✅ | Enllaç a Settings → Legal |

| 3 | DPA soft-duty (ack, no e-sign) | ✅ | `dpa_acknowledged_at` + banner Legal; audit |

| 4 | Gate selectiu IA | ✅ | Checklist REC-8 intacte + hint Legal |

| 5 | Rights page → política candidats | ✅ | `resolvePrivacyUrlForSite` |



### Fora d’abast



- Signatura comercial DocuSign / e-sign de la DPA.

- Moure `default_max_retention_months` fora de recruitment (resta operatiu).



---



## LC-0 … LC-3



Veure historial / EXECUTION.



---



## QA hardening (post LC-4)



| # | Ítem | Estat | Evidència |

|---|------|-------|-----------|

| 1 | Staff report-scoped + `retention_status` | ✅ | Migració `00047` |

| 2 | Redirects `external_url` només https | ✅ | CP / PP / empleat + Settings |

| 3 | Mode `edited` sense publish UI | ✅ | Opció oculta + avís |

| 4 | Dashboard CP locale footer/cookies | ✅ | `DashboardBulletinList` |

| 5 | Footer CP termes | ✅ | `portal_terms_customers` |

| 6 | Preview Legal sanititzat | ✅ | DOMPurify |

| 7 | `dpa_platform` fora d’allowlists públiques | ✅ | CP / slug / CD / empleat |

| 8 | Custom domain lead privacy sense slug | ✅ | `tenantId` + `linkBase: locale` |

| 9 | Guia de prova manual | ✅ | [`QA.md`](./QA.md) |


