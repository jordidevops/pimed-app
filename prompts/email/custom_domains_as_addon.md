DONE
Aquesta és una decisió estratègica molt encertada. Mantenir-se a Resend per ara simplifica l'arquitectura, i gestionar el control de dominis com una funcionalitat de pagament (add-on) és el model estàndard en el programari SaaS B2B.

Per implementar aquest "Feature Flag" i el control de quotes per domini, cal tocar quatre punts clau. Aquí tens l'estudi tècnic i el prompt final per a la IA.

### 1. Canvis a la Base de Dades (SQL)
Necessitem ampliar la configuració d'email per cada tenant per incloure els permisos i els límits.
* **Taula `data.email_configs`**: Afegir `custom_domains_enabled` (boolean) i `max_custom_domains` (integer, defecte 1).
* **Seguretat**: Crear una funció de validació que impedeixi inserir a `data.email_domains` si el tenant ha arribat al seu límit.

### 2. Canvis en l'Edge Function (`manage-email-domain`)
La funció de registre ha de ser la "policia" que verifiqui el permís abans de parlar amb Resend.
* Abans d'executar l'acció `register`, cal llegir la config del tenant i validar:
    1.  Si `custom_domains_enabled` és `true`.
    2.  Si el nombre de dominis actuals és menor que `max_custom_domains`.

### 3. Canvis als Portals (UI)
* **Admin-Portal**: Una nova secció a la fitxa del Tenant per activar/desactivar la funcionalitat i definir quants dominis pot tenir.
* **Tenant-Portal**: Si la funcionalitat està desactivada, la pestanya de dominis ha de mostrar un missatge de "Contacta amb vendes per activar dominis personalitzats". Si ha arribat al límit, s'ha d'amagar el botó d'afegir.

---

### Prompt definitiu per a la IA

Pots passar aquest prompt a la IA que tinguis amb accés al codi:

> **Rol:** Senior Fullstack Engineer & SaaS Architect.
>
> **Objectiu:** Implementar un sistema de "Feature Flag" i quotes per als dominis personalitzats d'email, gestionat per tenant i amb control de facturació addicional.
>
> **Tasques a realitzar:**
>
> **1. SQL (`20260415000002_email_system_core.sql`):**
> * Afegeix a la taula `data.email_configs` les columnes:
>   * `custom_domains_enabled`: boolean, per defecte `false`.
>   * `max_custom_domains`: integer, per defecte `1`.
> * Crea un trigger o una restricció (CHECK) que verifiqui abans d'inserir a `data.email_domains` si el tenant té permís i si no ha superat la seva quota.
>
> **2. Edge Function (`supabase/functions/manage-email-domain/index.ts`):**
> * Modifica l'acció `register`. Abans d'inserir a la BD o cridar Resend, consulta `data.email_configs`.
> * Si `custom_domains_enabled` és `false`, retorna un error `403` explicant que la funcionalitat no està inclosa en el seu pla.
> * Si el recompte de dominis existents per a aquest tenant és `>= max_custom_domains`, retorna un error explicant que ha arribat al límit de dominis contractats.
>
> **3. Admin-Portal (Gestió de la quota):**
> * A la pàgina de configuració de tenants de l'Admin-Portal, afegeix un switch per a "Habilitar Dominis Personalitzats" i un input numèric per a "Límit de Dominis".
> * Assegura't que aquests camps actualitzin `data.email_configs`.
>
> **4. Tenant-Portal (`EmailDomainsTab.tsx`):**
> * Carrega els camps `custom_domains_enabled` i `max_custom_domains` des de la config del tenant.
> * Si la funcionalitat està desactivada, mostra un estat buit (Empty State) amb un botó d'acció per contactar amb suport/vendes.
> * Si la funcionalitat està activa però el tenant ha arribat al límit (ex: 1/1), amaga el formulari d'afegir nou domini i mostra un missatge: "Has arribat al límit de dominis inclosos. Vols afegir-ne un altre? [Botó de contacte]".
>
> **Consideració de disseny:** Manté la lògica de que el primer domini verificat es marqui automàticament com a `is_primary`.


---

Amb aquest canvi, podràs cobrar, per exemple, 5€/mes per cada domini extra que un tenant vulgui verificar, o incloure un sol domini només en els teus plans "Enterprise" o "Premium". Això soluciona el problema dels costos de Resend i et genera una nova via d'ingressos.