
---

### Prompt Definitiu i Corregit: Calendari Genèric (Integrat amb Hub & Spoke i RBAC Multi-Site)

> **Rol:** Principal Software Engineer & Supabase Architect.
>
> **Objectiu:** Dissenyar un sistema de Calendari Multi-tenant i Multi-site Genèric basat en el patró 'Read Model' (CQRS), integrat amb la nostra arquitectura 'Hub and Spoke' d'Addons i preparat per al nou sistema de seguretat RBAC basat en permisos injectats al JWT amb context de Site.
>
> **Tasques a realitzar:**
>
> **1. SQL DDL (`app.calendar_events`):**
> * Crea la taula amb suport polimòrfic (`entity_type`, `entity_id`).
> * Obligatori usar `TIMESTAMPTZ` per a `start_at` i `end_at`.
> * Inclou `module_id` (vinculat al concepte de mòduls/addons del sistema).
> * **Clau per al Context Multi-Site:** Afegeix `site_id UUID REFERENCES data.sites(id) ON DELETE CASCADE`. Si és NULL, l'esdeveniment és global per al tenant.
> * **Clau per a RLS:** Afegeix camps per gestionar RLS sense fer JOINs dinàmics. Afegeix el camp `required_permissions TEXT[]` (ex: `['invoices.view']`) i `owner_id UUID`.
> * Crea índexos compostos per a consultes mensuals òptimes (`tenant_id`, `site_id`, `start_at`, `end_at`).
>
> **2. RLS Policies:**
> * Genera polítiques on l'usuari pugui llegir només els events del seu `tenant_id`.
> * **Validació de permisos basada en context (Multi-Site):** La política ha de comprovar ràpidament el JWT (`auth.jwt() -> 'app_metadata' -> 'user_tenants'`).
>   - Si l'event té `site_id IS NULL`, comprova si hi ha intersecció de `required_permissions` amb els permisos globals del tenant al JWT.
>   - Si l'event té `site_id`, comprova la intersecció amb els permisos específics d'aquell site al JWT (o els globals, ja que el global hereta cap a baix).
>   - *Bypass:* Si l'usuari n'és el `owner_id`, sempre ho pot veure.
>
> **3. RPC Transaccional (No Triggers):**
> * Escriu una funció PL/pgSQL (RPC) d'exemple, com `api.create_task_with_event()`, que demostri com inserir una entitat de negoci i el seu corresponent registre a `calendar_events` dins de la mateixa transacció atòmica (`BEGIN...COMMIT`), passant-li explícitament els `required_permissions` i el `site_id` si escau.
>
> **4. Frontend Registry Pattern (React/Next.js):**
> * Implementa un patró 'Registry' en TypeScript on cada mòdul pugui registrar els seus components visuals per al calendari (colors, icones, modals de detall).
> * El Registry també ha de definir quins permisos calen per veure o editar aquell tipus d'event (ex: `viewPermission: 'invoices.view'`).
> * El component `<CalendarWidget />` ha de ser totalment mut. En renderitzar una targeta d'event, o en fer-hi clic, **ha d'utilitzar el hook `usePermission(registry.editPermission, event.site_id)`** per determinar de forma dinàmica si l'usuari té permís d'edició en aquell site específic.
> * Afegeix lògica al Frontend: Si el `module_id` de l'event correspon a un addon que està `canceled` o `expired` per al tenant actual, l'event s'ha de mostrar en gris/read-only o amagar-se.

---

