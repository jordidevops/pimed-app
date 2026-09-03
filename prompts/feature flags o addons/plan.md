# Implementació de Feature Flags i Addons (Hub and Spoke)

Aquest document detalla el pla per implementar la gestió i facturació de feature flags (mòduls/addons) a l'aplicació, seguint el patró **Hub and Spoke** i complint amb els requisits de facturació per dies, períodes de prova i aïllament de funcionalitats.

## User Review Required

> [!IMPORTANT]
> **Aprovació del model de dades:** Si us plau, revisa la nova taula `data.tenant_addons` i la lògica de prorrateig proposada. És fonamental validar si prefereixes integrar els addons a la taula existent `data.subscriptions` o mantenir-los separats en `data.tenant_addons` (recomanat per flexibilitat).

## Open Questions

> [!WARNING]
> 1. **Facturació / Prorrateig:** Actualment, l'aplicació delega la facturació completament a una passarel·la (ex: Stripe) o voleu que la base de dades (Postgres) calculi exactament l'import a facturar abans d'enviar-ho a Stripe? (Stripe ja té suport natiu per prorrateig diari si s'utilitzen `Subscription Items`).
> 2. **Cron Jobs:** Per desactivar els *trials* automàticament un cop vençut el termini, recomanem utilitzar **pg_cron** (disponible a Supabase) per executar una funció diària que comprovi i expiri els addons, o bé una **Edge Function** invocada per un cron. Quina opció prefereixes?

## Proposed Changes

La implementació es dividirà en la capa "Hub" (Productes i Subscripcions a Addons) i el "Bridge" (Triggers que apliquen els canvis a les taules Spoke de configuració).

### Capa Hub (Base de dades)

Es crearan les taules centrals per gestionar el catàleg d'addons i les subscripcions dels tenants.

#### [NEW] `supabase/migrations/2026XXXXXXXXX_hub_and_spoke_core.sql`
- **Taula `data.billing_addons` (El Catàleg):**
  - `id`: text (ex: `addon_custom_domains`)
  - `name`: text (ex: "Dominis Personalitzats")
  - `price_monthly`: numeric (preu mensual base)
  - `trial_days`: integer (ex: 14 dies de prova, si aplica)
  - `trial_cooldown_months`: integer (temps d'espera per tornar a fer un trial, ex: 6 mesos)
  - `spoke_config`: jsonb (ex: `{"table": "email_configs", "features": {"custom_domains_enabled": true, "max_custom_domains": 1}}`)
- **Taula `data.tenant_addons` (Les Subscripcions Actives):**
  - `id`: uuid
  - `tenant_id`: uuid (FK a `data.tenants`)
  - `addon_id`: text (FK a `data.billing_addons`)
  - `status`: text (`active`, `trial`, `canceled`, `expired`)
  - `started_at`: timestamptz (inici de l'activació)
  - `trial_ends_at`: timestamptz (quan acaba el trial)
  - `trial_available_again_at`: timestamptz (quan pot tornar a fer trial)
  - `canceled_at`: timestamptz (quan es va desactivar, per calcular el prorrateig)
  - `stripe_subscription_item_id`: text (per enllaçar amb Stripe si cal)

### Bridge (Triggers de Sincronització)

Quan l'estat d'un addon canvia, un trigger s'encarrega d'injectar o retirar els permisos a la taula Spoke corresponent.

#### [NEW] `supabase/migrations/2026XXXXXXXXX_hub_and_spoke_triggers.sql`
- **Funció `data.sync_addon_to_spoke()` i Trigger:**
  - `AFTER INSERT OR UPDATE OF status ON data.tenant_addons`
  - La funció llegeix el `spoke_config` del catàleg.
  - Si el nou estat és `active` o `trial`, genera una consulta dinàmica (o gestionada mitjançant un CASE/IF si es volen evitar consultes dinàmiques per seguretat) per actualitzar la taula corresponent. Ex: `UPDATE data.email_configs SET custom_domains_enabled = true...`
  - Si el nou estat és `canceled` o `expired`, fa l'equivalent per revocar els permisos, posant a false o limitant valors. Així les dades (dominis) no s'esborren i **no es trenca cap altra funcionalitat**.

### Gestió de Trials i Prorrateig

- **Funció de desactivació de Trials (Cron Job):**
  - Crearem una funció Postgres `data.expire_trials()` que busqui registres a `data.tenant_addons` on `status = 'trial'` i `trial_ends_at < now()`.
  - Canviarà el seu estat a `expired` i posarà `trial_available_again_at = now() + interval 'X months'` basat en el cooldown del catàleg.
  - Això dispararà automàticament el trigger del Bridge, desactivant la feature a la taula Spoke.
- **Registre per Prorrateig (Ús Diari):**
  - Quan un usuari cancel·la un addon actiu enmig del mes, registrem `canceled_at`.
  - La fórmula de facturació local seria calcular els dies actius: `date_part('day', canceled_at - started_at)`.
  - Si es fa servir Stripe, recomanem usar el seu sistema de prorrateig nativa: el webhook de cancel·lació o *downgrade* actualitza l'estat local. Si no teniu passarel·la, es pot crear una vista `api.billing_summary_view` que reculli les dades i càlculs.

### Integració amb UI (Backend d'API)

#### [NEW] Vistes i Funcions per al Frontend
- Vista `api.addons`: Exposa el catàleg de mòduls disponibles (`data.billing_addons`).
- Vista `api.tenant_addons`: Mostra al tenant quins addons té actius, si estan en trial, quan expira el trial i quan podria tornar a demanar-lo.
- **Funcions RPC (Remote Procedure Call):**
  - `api.toggle_addon(p_addon_id text, p_enable boolean)`: Permetrà a l'usuari activar/desactivar un mòdul des del panell. Si l'activa per primer cop i té trial configurat, començarà el trial. Si s'activa com a compra, s'actualitzarà com a 'active' (i invocarà la facturació si escau).

## Verification Plan

### Automated Tests
1. **Proves de Base de Dades (pgTAP o test manual SQL):**
   - Inserir un addon a `data.tenant_addons` amb estat `trial`. Comprovar que `data.email_configs.custom_domains_enabled` s'ha posat a `true`.
   - Modificar l'estat a `expired` o `canceled`. Comprovar que `data.email_configs` canvia a `false` sense eliminar dades de `data.email_domains`.
   - Executar la funció `data.expire_trials()` per comprovar que els trials vençuts canvien d'estat automàticament.

### Manual Verification
1. L'usuari del sistema ha d'aprovar aquest disseny arquitectònic abans de procedir.
2. Es podran fer proves d'activació i desactivació de mòduls via client (UI o scripts RPC) validant que les característiques s'activen o es retiren sense cap altre impacte col·lateral a l'aplicació.
