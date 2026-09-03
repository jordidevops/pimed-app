
***

### Prompt per a IA: Implementació del Frontend del Calendari (SaaS Suite)

"Actua com un **Senior Frontend Engineer expert en React, Tailwind CSS i Lucide React**. Ara que ja tenim la infraestructura de base de dades i permisos, hem d'implementar el **Widget de Calendari** al `tenant-portal`. 

L'objectiu és crear un sistema totalment modular on cada mòdul (CRM, Invoices, HR) pugui "registrar" els seus esdeveniments.

**Tasques a realitzar:**

**1. Calendar Registry (Arquitectura Modular):**
- Crea un fitxer `lib/calendar-registry.ts` que implementi un patró Singleton. 
- Cada mòdul ha de poder registrar: `type`, `color` (Tailwind), `icona`, `permissionKey` i un `component de detall`.
- Defineix la interfície TypeScript estricta per a aquests mòdul.

**2. Hook de Dades (`useCalendarEvents`):**
- Implementa un hook usant **React Query** que consumeixi la taula `app.calendar_events`.
- Ha de suportar filtres per `range` (inici/final de mes) i el `selectedSiteId` del context de l'aplicació.
- Ha de realitzar el "Join" conceptual: si l'event diu que és de tipus `invoice`, el hook ha de recuperar la configuració del Registry per saber quin color i icona aplicar-li.

**3. Component `<CalendarWidget />` (Mobile-First UX):**
- Crea el component principal amb una **Vista Dual**:
    - **Desktop (> 768px):** Una graella mensual clàssica (CSS Grid).
    - **Mòbil (< 768px):** Un selector de dates horitzontal (setmana actual) i una llista d'agenda vertical a sota (tipus Google Calendar mòbil).
- Implementa gestos (swipe) per canviar de mes o setmana.
- Utilitza la llibreria **Vaul (Drawer)** per obrir els detalls dels esdeveniments en mòbil (full inferior que puja) i **Dialog (Shadcn)** en desktop.

**4. Integració amb Seguretat i Addons:**
- En fer clic a un esdeveniment, utilitza el hook `usePermission(event.permissionKey, event.site_id)` que hem definit abans.
- **Lògica de bloqueig:** Si l'usuari no té permís d'edició, el formulari de detall ha de sortir en mode 'Només lectura'.
- **Lògica d'Addons:** Si el `module_id` de l'esdeveniment correspon a un addon que no està actiu per al tenant (comprovant `my_tenant_addons`), mostra un estat 'desactivat' amb un missatge d'actualització de pla.

**5. Estils i Rendiment:**
- Utilitza Tailwind per als estils.
- Optimitza el rendiment usant `memo` en els dies de la graella per evitar re-renderitzats innecessaris en canviar de mes.

Genera el codi per al Registry, el Hook principal i l'esquelet del Widget amb la vista dual."

***

