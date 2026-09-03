Un altre concepte que m'agradaria afegir és la organització de la infraestructura dels actius del tenant, bàsicament del seus sites en nodes o zones jeràrquiques. Similar al sistema de permisos  i rols de la app però respecte ala actius empresarials. Per exemple, un site pot ser un restaurant, una fàbrica, etc i aquest té zones de treball on hi poden haver màquines, equips,... i on poden treballar empleats o fitxar-hi.
Com es podria contemplar això de manera genèrica i general abans d'introduïr móduls específics que ho utilitzin, per exemple fitxar control horari un empleat, manteniment d'equips,...?



Aquesta és una reflexió de disseny de sistemes d'altíssim nivell. Estàs entrant al territori dels sistemes **EAM (Enterprise Asset Management)** i **CAFM (Computer-Aided Facility Management)**. Si dissenyes això bé des del principi, el teu SaaS podrà suportar des d'una petita cafeteria fins a una cadena de muntatge industrial sense canviar ni una coma de la base de dades.

L'error més comú aquí és intentar barrejar "l'espai físic" amb "les màquines" en una sola taula. En el món real, una màquina es pot moure d'una sala a una altra, o portar-se a reparar. 

Per contemplar-ho de manera genèrica i robusta, necessitem introduir dos conceptes separats però relacionats abans de tocar cap mòdul específic:

### 1. Jerarquia Espacial (`data.locations`)
Aquesta taula representa **l'espai físic**. És una estructura en arbre (Adjacency List) on un espai pot contenir sub-espais infinitament.
* **Estructura:** `Site` (Fàbrica) ➔ `Location` (Nau 1) ➔ `Sub-Location` (Planta Baixa) ➔ `Sub-Location` (Zona d'Empaquetatge).
* **Com es fa:** Una taula `data.locations` amb una columna `parent_id` que s'apunta a si mateixa, i un `site_id` que la vincula al local principal.

### 2. Gestió d'Actius (`data.assets` o `data.equipment`)
Aquesta taula representa **les coses** (físiques o lògiques) que requereixen manteniment, inspecció o ús.
* **Com es fa:** Els actius tenen la seva pròpia taula i tenen una columna `location_id`.
* **L'Avantatge:** Si el "Forn 2" s'espatlla i s'envia a reparar al magatzem, simplement canvies el seu `location_id`. Tot l'historial de manteniment, codis QR, i manuals del forn viatgen amb ell.

### Com s'integrarà això amb els futurs mòduls?
* **Control Horari (HR):** Un treballador fitxa posant l'ID d'una `location` (ex: Entrada Nau 2). Podem comprovar la distància entre el GPS del mòbil i el JSONB `geo_coordinates` d'aquella `location`.
* **Manteniment (Work Orders):** Quan crees una incidència, informes que falla l'`asset` (Màquina de Cafè), que actualment es troba a la `location` (Barra Principal) del `site` (Restaurant Centre).
* **Seguretat (RLS):** Gràcies al fet que tant `locations` com `assets` pengen sempre d'un `site_id`, les mateixes regles RLS que ja tenim funcionaran automàticament de forma ultra-ràpida.

---

### El Prompt per establir aquesta Fundació

Per generar aquesta infraestructura genèrica de manera correcta, aquí tens el prompt que li has de passar a la IA de codi:

> **Rol:** Principal Software Engineer & Data Architect.
>
> **Objectiu:** Implementar una infraestructura genèrica de Gestió d'Espais i Actius (Locations & Assets) per a un SaaS Multi-Tenant i Multi-Site. Aquesta capa servirà de base per a futurs mòduls com Manteniment, Control Horari o Gestió d'Inventari.
>
> **Tasques a realitzar:**
>
> **1. Taula de Jerarquia Espacial (`data.locations`):**
> * Crea la taula amb `tenant_id`, `site_id` i `parent_id UUID REFERENCES data.locations(id) ON DELETE CASCADE` (per permetre sub-zones infinites).
> * Afegeix camps genèrics: `name`, `type` (ex: floor, room, zone, outdoor), `status` (active, maintenance, inactive), i `geo_coordinates JSONB` per delimitar la zona.
> * Crea índexos per `site_id` i `parent_id`.
>
> **2. Taula d'Actius / Equips (`data.assets`):**
> * Crea la taula representant maquinària o equips físics.
> * Camps obligatoris: `tenant_id`, `site_id`, `location_id UUID REFERENCES data.locations(id) ON DELETE SET NULL`.
> * Camps descriptius: `name`, `serial_number`, `asset_tag` (per futurs codis QR), `status` (operational, down, repairing), i `metadata JSONB` per a especificacions tècniques variables.
> * Crea índexos per `location_id`, `site_id` i `asset_tag`.
>
> **3. Seguretat RLS (Herència de Site):**
> * Aplica polítiques RLS per a ambdues taules.
> * L'accés de lectura ha de ser el mateix que tenim definit per als Sites: l'usuari pot veure les `locations` i `assets` si el JWT indica que té accés a aquell `tenant_id` i `site_id` (o rol global).
> * L'accés d'escriptura (INSERT/UPDATE/DELETE) ha d'estar restringit a usuaris amb permisos de gestió (`manager`, `owner`, o permisos granulars futurs).
>
> **4. Vistes Públiques (`api.locations` i `api.assets`):**
> * Crea les vistes dins de l'esquema `api` amb `security_invoker = true` per exposar aquestes taules al `tenant-portal` de forma segura.

---

Amb aquestes dues taules al seu lloc, el teu SaaS assoleix una dimensió completament nova i està absolutament preparat per integrar l'estudi de gestió d'obres/manteniment que vam parlar abans. 

Vols que llancem aquest prompt de "Locations i Assets" abans de procedir amb l'estudi de les Work Orders i el sistema de Jobs asíncron?