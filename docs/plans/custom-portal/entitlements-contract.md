# Contracte versionat — `portal_entitlements.customer_portal`

> **Contracte CP-0.7** — 2026-08-04.  
> Schema version: **1.0**  
> Pla: [`README.md`](./README.md) · Resolució efectiva descrita al mateix README § Plans.

Text comercial orientatiu: **«Clients i usuaris del portal sense llicència per seient, subjectes a ús raonable.»**  
No prometre «il·limitat» absolut sense la clàusula d’ús raonable i restricció operacional.

---

## 1. JSON canònic (pla / snapshot)

```json
{
  "customer_portal": {
    "included": true,
    "mode": "portal",
    "customer_users_limit": null,
    "active_share_guardrail": 500,
    "customer_mau_alert_threshold": 1000,
    "included_email_deliveries_month": 2000
  }
}
```

La notació documental `share_only|portal` significa un dels dos valors; **mai** es persisteix el literal amb `|`.

---

## 2. Semàntica de camps

| Camp | Tipus | Significat |
|---|---|---|
| `included` | boolean | El pla/contracte concedeix el mòdul |
| `mode` | `"share_only"` \| `"portal"` | Capacitat **màxima** del tenant. `portal` = superconjunt (shares **i** grants). No classifica cada client |
| `customer_users_limit` | `null` \| number | `null` = sense quota de seats/clients. No consumeix `max_members` |
| `active_share_guardrail` | number | Màxim de shares actives; bloqueja **noves** creacions, no revoca existents |
| `customer_mau_alert_threshold` | number | Soft: alerta comercial; **no** bloqueja automàticament. Sessions staff i sessions anònimes de share **no** entren a customer MAU |
| `included_email_deliveries_month` | number | Enviaments inclosos; política comercial a superar (revisió / overage / bloqueig de nous emails) sense tallar l’accés web per si sol |

**Fora d’aquest JSON:** retenció legal, kill-switch, `new_access_policy`, etc. → estat operacional / polítiques RGPD.

---

## 3. Seed inicial de plans

Tots els plans vigents: `included: true`.

| Fase de producte | `mode` efectiu màxim |
|---|---|
| CP-A (butlletí + shares) | `share_only` (rollout impedeix grants) |
| CP-B disponible | Migració **additiva** a `portal` a tots els plans |

Sync amb pla: només millores (`share_only` → `portal`, guardrails més alts, més emails). Reduccions = acció admin explícita + audit.

---

## 4. Capacitats resoltes (API)

`resolve_portal_entitlements` ha d’exposar, entre altres:

```json
{
  "customer_portal": {
    "included_granted": true,
    "included_plan": true,
    "enabled_by_tenant": true,
    "effective": true,
    "mode_granted": "portal",
    "mode_plan": "portal",
    "mode_effective": "portal",
    "can_create_shares": true,
    "can_grant_portal_access": true,
    "customer_users_limit": null
  }
}
```

Frontends consumeixen `can_create_shares` / `can_grant_portal_access`; no reimplementen la jerarquia de modes.

---

## 5. Versionat

- Bump de **schema version** d’aquest fitxer quan s’afegeixin/renombrin camps.
- Implementació SQL/UI (CP-ADM / CP-A2) ha de validar contra aquesta versió i preservar claus JSON desconegudes en desar.
- Canvis incompatibles: migració de snapshot + nota al changelog de [`STATUS.md`](./STATUS.md).
