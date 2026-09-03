DONE
# Context i Objectiu
Estem construint una aplicació SaaS multitenant utilitzant Supabase i PostgreSQL. Volem implementar un sistema de **Feature Flags / Addons facturables** utilitzant el patró arquitectònic "Hub and Spoke".

L'objectiu d'aquest patró és separar completament la configuració tècnica dels límits (els Spokes, ex: `email_configs`) de la lògica de negoci i facturació (el Hub, ex: `tenant_addons` i `billing_addons`).

Quan l'estat d'una subscripció a un addon canvia (inici d'un trial, activació, o cancel·lació), un trigger a la base de dades s'encarrega d'habilitar o deshabilitar les "features" a les taules de configuració corresponents. És crucial que **desactivar un mòdul no trenqui la funcionalitat ni esborri dades**, simplement ha de bloquejar l'ús d'aquella funcionalitat (ex. posant `custom_domains_enabled = false`).

# Requisits Tècnics

Si us plau, genera una o diverses migracions SQL per a Supabase que implementin el següent:

## 1. Taules del Hub (Catàleg i Subscripcions)
Crea les següents taules a l'esquema `data` (s'ha d'activar el RLS a totes elles):

* **`data.billing_addons`** (Catàleg de mòduls disponibles):
  * `id` (text, PRIMARY KEY, ex: 'addon_custom_domains')
  * `name` (text, ex: 'Dominis Personalitzats')
  * `price_monthly` (numeric(10,2), preu mensual de l'addon)
  * `trial_days` (integer, defecte 0 o NULL)
  * `trial_cooldown_months` (integer, defecte 6, mesos que han de passar per poder tornar a demanar un trial)
  * `spoke_config` (jsonb, defineix on s'aplica aquest addon. Ex: `{"table": "email_configs", "features": {"custom_domains_enabled": true, "max_custom_domains": 1}}`)
  * Columnes `created_at` i `updated_at`.

* **`data.tenant_addons`** (L'estat actiu de l'addon per a cada tenant):
  * `id` (uuid, PRIMARY KEY)
  * `tenant_id` (uuid, NOT NULL, referència a `data.tenants` en cascada)
  * `addon_id` (text, NOT NULL, referència a `data.billing_addons`)
  * `status` (text, check in ('active', 'trial', 'canceled', 'expired'))
  * `started_at` (timestamptz, defecte now())
  * `trial_ends_at` (timestamptz)
  * `trial_available_again_at` (timestamptz)
  * `canceled_at` (timestamptz, per a càlculs de prorrateig)
  * `stripe_subscription_item_id` (text, opcional, per lligar a Stripe)
  * Columnes `created_at` i `updated_at`.
  * Restricció: Únic (tenant_id, addon_id) parcial o gestió d'historial. El millor és permetre una única fila "activa" per addon i tenant, o bé permetre'n vàries però on només una estigui activa/en trial.

## 2. Lògica de Prorrateig de Facturació a Postgres
Volem calcular de forma local el prorrateig de l'ús de l'addon abans de delegar a Stripe.
* Crea una vista `api.addon_billing_proration` que calculi la fracció de mes que un tenant ha usat l'addon, en cas que se li cancel·li (`status = 'canceled'`) abans de completar el cicle mensual.
* Ha de fer la diferència entre `canceled_at` i `started_at` (o l'inici del mes de facturació) i mostrar l'import pendent teòric basat en el `price_monthly`. Aquest càlcul es mostrarà a l'admin-portal per informar a l'usuari. (Stripe farà el càlcul definitiu).

## 3. Desactivació automàtica de Trials via pg_cron
Crea una funció `data.expire_trials()` en PL/pgSQL que faci el següent:
* Busqui a `data.tenant_addons` els registres on `status = 'trial'` i `trial_ends_at < now()`.
* Per a cadascun, actualitzi l'estat a `expired`.
* Actualitzi `trial_available_again_at` sumant els `trial_cooldown_months` (extrets de `billing_addons`) al moment actual (`now()`).
* **Programa aquesta funció** perquè s'executi cada hora o diàriament utilitzant l'extensió `pg_cron` (fes un `SELECT cron.schedule('expire_trials', '0 * * * *', 'SELECT data.expire_trials()');`).

## 4. El "Bridge" (Trigger de Sincronització Hub -> Spoke)
* Crea una funció de trigger `data.sync_addon_to_spoke()` en PL/pgSQL que salti `AFTER INSERT OR UPDATE OF status ON data.tenant_addons`.
* Aquesta funció ha de llegir el `spoke_config` del catàleg associat (`addon_id`).
* Si l'estat passa a `active` o `trial`, ha de construir i executar de forma segura (dinàmicament) un `UPDATE` a la taula que indiqui el JSON (ex: `data.email_configs`), i posar-li els valors del camp `features` a la fila corresponent al `tenant_id`.
* Si l'estat passa a `canceled` o `expired`, ha de fer l'efecte invers: extreure els permisos (ex: posar a `false` els booleans de la `features` del JSON o posar el límit a 0 o al seu valor per defecte).

# Punts Clau a tenir en compte
* Mantén tot l'esquema d'usuari i de configuració separat del negoci.
* Pensa en la seguretat: utilitza tipus forts, verificacions (`CHECK`), i `SECURITY DEFINER` allà on sigui necessari pels triggers.
* Recorda afegir Polítiques RLS bàsiques perquè només el tenant pugui llegir els seus `tenant_addons`, exposant les vistes públiques necessàries a l'esquema `api`.
* Escriu el codi ben comentat en format SQL per posar en una migració de Supabase.
