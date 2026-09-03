
DONE
***

### Prompt per a la IA: Millores d'UX, Realtime i Consums al Tenant-Portal

> **Rol:** Senior Fullstack Engineer (Next.js, Supabase, Tailwind).
>
> **Objectiu:** Professionalitzar la secció de correu del Tenant-Portal millorant la visualització de consums, activant el Realtime real i unificant la interfície de l'historial amb la de l'Admin-Portal.
>
> **Tasques a realitzar:**
>
> **1. Visualització de Consums (Targeta "Límits de quota"):**
> * **Backend:** Crea una funció RPC `api.get_my_email_usage()` (SECURITY DEFINER) que consulti la taula `data.worker_rate_limits` per al tenant actual. Ha de retornar el sumatori de correus enviats en l'hora actual i en el dia actual.
> * **Frontend:** A la targeta "Límits de quota actuals", afegeix indicadors de progrés (progress bars) o comptadors que mostrin: "Enviats avui: X / Límit" i "Enviats darrera hora: Y / Límit". Afegeix un botó de "Refrescar" per carregar aquestes dades a petició.
>
> **2. Realtime a l'Historial:**
> * Revisa la subscripció a Supabase Realtime al component de l'historial del Tenant-Portal.
> * **Problema:** Tot i que la taula `data.email_logs` està a la publicació `supabase_realtime`, el component no s'està actualitzant quan s'afegeixen nous registres a la cua.
> * **Solució:** Assegura't que el filtre de la subscripció `channel` inclou el `tenant_id` correctament i que l'estat local de la llista de correus s'actualitza immediatament en rebre un esdeveniment `INSERT` o `UPDATE`.
>
> **3. Refactorització de la Taula d'Historial (Tenant-Portal):**
> * **Unificació de Lògica:** Aplica la mateixa lògica de paginació des del servidor, ordenació per columnes i filtratge per estat que hem implementat a l'Admin-Portal.
> * **Simplificació de Columnes:** Elimina les columnes que no aporten valor al client: Nom del tenant (ell ja sap qui és), icones de sincronització (webhook/manual), intents i temps a la cua. Deixa: Data, Destinatari, Assumpte i Estat.
> * **Filtre Temporal:** Per defecte, la taula només ha de carregar els correus dels **últims 7 dies**. Permet que l'usuari ampliï el rang fins al màxim permès per la seva quota de retenció (`retention_days`).
>
> **4. Modal de Detalls del Correu:**
> * Simplifica el modal per a l'usuari final.
> * **Eliminar:** Botó de sincronització manual, camps tècnics de temps (locked_at, etc.) i el JSON de metadades.
> * **Mantenir:** Detalls del remitent, destinataris, còpies, estat detallat, l'historial d'errors (si n'hi ha) i la previsualització del contingut si està disponible.
>
> **Consideració tècnica:** Totes les consultes han de continuar respectant l'RLS i l'esquema `api` per seguretat.

***
