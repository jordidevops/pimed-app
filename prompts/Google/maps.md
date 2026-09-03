Aquest és un dels grans reptes dels SaaS B2B. Quan parlem de mapes, els costos es poden disparar molt ràpidament.

Abans de parlar de facturació, cal fer una distinció vital per al teu projecte, ja que tens **PostGIS** configurat a la base de dades:

* **El que és GRATIS (PostGIS al Backend):** Saber quin tècnic està més a prop d'un equip avariat (càlcul de distàncies radials) o comprovar si un tècnic està dins de la zona assignada (geofencing). Tot això ho fa PostgreSQL internament. No et costa res extra.
* **El que ES PAGA (Google Maps):** Dibuixar el mapa visualment a la pantalla de React, convertir una adreça de text en coordenades (*Geocoding*), o calcular la ruta òptima en cotxe tenint en compte el trànsit (*Directions API*).

Per repercutir aquests costos de Google Maps als teus *tenants*, tens dues estratègies principals:

### Opció 1: "Bring Your Own Key" (BYOK) - Recomanada
Aquesta és la via més segura per a tu. El teu SaaS no posa la targeta de crèdit, sinó que l'empresa d'equips (el tenant) utilitza el seu propi compte de Google.

* **Com funciona:** A la pantalla de "Configuració" del teu *tenant-portal*, hi ha un camp on el client enganxa la seva pròpia clau API de Google Maps (`AIzaSy...`).
* **L'Avantatge Econòmic:** Google Maps regala **200$ mensuals de crèdit gratuït** a cada compte. Si cada tenant posa la seva clau, aprofita els seus propis 200$, cosa que en el 90% dels casos significa que el mapa serà gratuït per a ells. A tu el cost de mapes et surt per 0€.
* **Com es programa:** Al teu frontend de React, en lloc de posar la clau al fitxer `.env`, utilitzes la llibreria oficial `@googlemaps/js-api-loader` per carregar el mapa dinàmicament utilitzant la clau que llegeixes de la base de dades per a aquell tenant.

### Opció 2: Clau Centralitzada + Plans de Subscripció
Utilitzes una única clau API de la teva empresa per a tots els clients.

* **El problema de facturar per ús (Metered):** Fer un seguiment exacte de quants cèntims ha gastat cada tenant al mapa és un malson tècnic, perquè l'API de Google Maps es carrega des del navegador del client, i Google no permet associar crides directes a "sub-comptes" fàcilment.
* **La solució (Venda per Paquets):** En lloc de cobrar-los cèntim a cèntim, crees funcionalitats "Premium".
    * *Pla Bàsic (50€/mes):* Llistat d'adreces en format text.
    * *Pla Pro (90€/mes):* Inclou la vista "Mapa en Temps Real" i seguiment de tècnics. Dins d'aquests 40€ de diferència, ja hi ha marge de sobres per cobrir el cost d'escriptura a Google Maps, i no t'has de preocupar de comptar crides API.

---

### Quina recomano per al teu cas?

Començar per l'**Opció 2 (Clau Centralitzada amb un sobrecost mensual al pla Pro)** és el més fàcil a nivell comercial. Als clients no els agrada haver de crear comptes a Google Cloud Developer i generar claus; volen pagar el teu programari i que tot funcioni.

### El Prompt per a la IA (Integració de Mapes Dinàmica)

Si vols preparar el terreny visual, aquí tens el *prompt* per demanar que et generin un component de mapa avançat per a l'aplicació, combinant React i dades.

> **Context:** Estem construint el `tenant-portal` (React 19, Vite) per a un SaaS multi-tenant. Necessitem un component per mostrar la posició dels tècnics.
>
> **Objectiu:** Escriu un component `LiveMap.tsx` que utilitzi l'API de Google Maps.
>
> **Requisits:**
> 1.  Utilitza la llibreria `@googlemaps/js-api-loader` per carregar el mapa, de manera que la clau API es pugui injectar dinàmicament com a *prop* (per si en el futur passem a un model BYOK on cada tenant té la seva clau).
> 2.  El component ha de rebre dues llistes per *props*: `elevators` (amb `lat`, `lng`, `status`) i `technicians` (amb `lat`, `lng`, `name`).
> 3.  Utilitza els marcadors avançats (`AdvancedMarkerElement`) per pintar les instal·lacions i els tècnics amb una icona diferent.
> 4.  Gestiona l'estat de càrrega i possibles errors en carregar el script de Google.
>
> **Sortida:** Només el codi del component React perfectament tipat.

Quin model veus més viable per als teus clients: fer que ells es barallin amb Google Cloud per aconseguir la seva clau API i estalviar-se diners, o apujar la teva quota i donar-los el servei "clau en mà"?