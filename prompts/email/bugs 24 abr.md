***

### Prompt per a la IA: Millores de Paginació, Filtratge i UX al Admin-Portal

> **Rol:** Senior React / Next.js Frontend Developer amb experiència avançada en Supabase i UI/UX.
>
> **Objectiu:** Resoldre bugs funcionals a la taula "Historial d'Emails" i unificar l'experiència de la taula "Missatges actius a la cua" per suportar paginació des del servidor, ordenació i filtratge.
>
> **Tasques a realitzar:**
>
> **1. Millores a la taula "Historial d'Emails" (`EmailLogsTable.tsx` o equivalent):**
> * **Filtre d'Estats (Status):** Revisa el component `Select` o `Dropdown` de l'estat. Assegura't que el valor seleccionat actualitza l'estat local i s'aplica correctament a la query de Supabase (`.eq('status', selectedStatus)`). Afegeix l'opció "Tots" per netejar el filtre.
> * **Ordenació per columnes (Sorting):** Fes que les capçaleres de les columnes principals (Data, Estat, Remitent, Prioritat) siguin clicables. Afegeix un estat `sortConfig` `{ column: string, ascending: boolean }` i aplica-ho a la query de Supabase amb `.order(column, { ascending })`. Mostra icones de fletxes (🔼/🔽) a la columna activa.
> * **Neteja del cercador (Clear Search):** A l'input de cerca de text, afegeix un botó "X" a la part dreta (només visible quan hi ha text) que, en clicar-lo, faci `setSearchQuery('')` i dispari una nova cerca automàticament.
> * **Navegació Primera/Última Pàgina:** Al component de paginació inferior, afegeix els botons de fletxa doble (`<<` per anar a la pàgina 1, i `>>` per anar a l'última). *Nota:* Per calcular l'última pàgina, assegura't que la query de Supabase inclou `{ count: 'exact' }` per obtenir el total de registres i divideix-ho pel nombre de files per pàgina.
> * **Altres errors:** El filtre per data no funciona. El botó "Exportar CSV" genera un arxiu amb només la fila de capcelera quan hauria de posar les mateixes files que son visibles a la taula. El filtratges per "Tenant" o "Site" tampoc funcionen.
>
> **2. Actualització de la taula "Missatges actius a la cua" (`QueueMonitorTable.tsx` o equivalent):**
> * **Refactor a Server-Side Pagination:** Actualment està limitat a 50. Modifica el fetch a `supabase.from('q_email_send_queue')` perquè accepti paginació (`.range(from, to)`).
> * **Implementació de Paginació:** Afegeix exactament el mateix component de paginació inferior (amb primera/última, anterior/següent i files per pàgina) que acabes d'arreglar a l'Historial.
> * **Ordenació (Sorting):** Permet ordenar per `msg_id` (o `enqueued_at`) i `vt` (Visibility Timeout).
> * **Filtratge (Filtering):** Afegeix un input de cerca que permeti filtrar els missatges de la cua. *Atenció:* Com que les dades de l'enviament viuen dins la columna JSONB `message`, la query de Supabase ha de buscar dins del JSON (ex: `.textSearch('message->>idempotency_key', query)` o `.eq('message->>tenant_id', query)` depenent de si es cerca per ID exacte o tenant).

***

