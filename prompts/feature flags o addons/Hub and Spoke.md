Estàs descrivint exactament el patró de disseny estàndard de la indústria SaaS, conegut com a **Separation of Entitlements and Configuration** (Separació de Permisos/Drets i Configuració). 

És una idea **brillant** preparar-ho així des d'ara mateix, perquè si barreges la lògica de facturació amb la configuració tècnica, quan integris Stripe o Paddle el teu codi es convertirà en un plat d'espaguetis.

Així és com s'estructura aquesta arquitectura "Hub and Spoke" (Centre i Radis):

### 1. El Centre (Hub): Taules de Facturació i Permisos
Aquestes taules només saben de diners, dates de renovació i quins "drets" ha comprat el tenant.

* **`data.billing_products` (El Catàleg):**
    * `id`: `addon_custom_domains`
    * `name`: "Domini Personalitzat"
    * `price`: 500 (5,00€)
    * `features`: `{"max_domains": 1, "rate_limit_bump": 500}` (Un JSON amb el que atorga aquest producte).
* **`data.tenant_subscriptions` (El Hub actiu):**
    * `tenant_id`: `123...`
    * `product_id`: `addon_custom_domains`
    * `status`: `active` (pot ser `past_due`, `canceled`).
    * `current_period_end`: `2026-05-24`
    * `stripe_subscription_id`: `sub_123...`

### 2. Els Radis (Spokes): Taules de Configuració
Aquestes taules no saben res de diners ni de Stripe. Només saben com funciona l'eina tècnicament.

* **`data.email_configs` (El que ja tens):**
    * `default_from_name`: "La meva Empresa"
    * `default_layout_id`: `uuid`
    * *(Ja no caldria posar aquí si ha pagat o no, perquè d'això se n'encarrega el Hub).*

### Com parlen entre elles? (El Flux Recomanat)

Per no haver de fer *JOINs* complexos a cada consulta de l'aplicació, el patró ideal és que el Hub **injecti** els límits a les taules de configuració quan canvia l'estat de la subscripció:

1.  El tenant compra l'Addon de Dominis a l'Admin Portal.
2.  Stripe processa el pagament i envia un **Webhook** al teu backend.
3.  El teu Webhook de billing actualitza `data.tenant_subscriptions` posant-ho a `active`.
4.  Un **Trigger de Postgres** (o el mateix webhook) actua com a pont: *"Ah! Aquest tenant acaba de pagar l'addon de dominis. Vaig a la taula `email_configs` i li poso `max_custom_domains = 1` i `custom_domains_enabled = true`"*.
5.  Si el client deixa de pagar, el Webhook posa la subscripció a `canceled`, i el trigger va a `email_configs` i ho posa a `false` (bloquejant l'enviament des d'aquell domini).

### Beneficis de fer-ho així:

1.  **Seguretat a l'Edge Function:** La teva funció `manage-email-domain` només ha de mirar una cosa molt ràpida a `email_configs` (puc o no puc afegir dominis?). No li importa si el pagament ha estat per transferència, per Stripe o si és un regal teu.
2.  **Unificació a l'Admin-Portal:** Tindràs una sola pantalla anomenada "Facturació i Addons" on veuràs tot el que té contractat un client, i des d'allà podràs activar o desactivar funcions manualment si fa falta.
3.  **Modularitat:** Demà fas un mòdul de "Generació de PDFs" o d'"IA". Fas la seva taula `pdf_configs` o `ai_configs`, i el Hub de facturació funcionarà exactament igual, simplement atorgant els permisos a la nova taula.

