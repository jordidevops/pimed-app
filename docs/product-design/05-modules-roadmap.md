# 5. Mapa de mòduls i ordre d'implementació

## 5.1 Estat actual (resum)

| # | Capa | Estat |
|---|---|---|
| 1 | Multi-tenant + Sites + RLS via JWT | ✅ |
| 2 | RBAC jeràrquic + permisos granulars (en curs) | 🟡 |
| 3 | Storage + DMS + ACL nodes | ✅ |
| 4 | Email system + plantilles + branding | ✅ |
| 5 | Hub & Spoke (addons) | ✅ |
| 6 | Audit logs + triggers | ✅ |
| 7 | Departments + Projects + Tasks | ✅ |
| 8 | Locations & Assets | ✅ |
| 9 | Calendari genèric | ✅ |
| 10 | Jobs / Events / Notifications worker (PGMQ) | ✅ |
| 11 | Contacts + ContactSites | ✅ |
| 12 | Catalog (products+services) + project_lines | ✅ |
| 13 | Industry Archetypes + Verticals + onboarding | 🟡 parcial (archetypes + onboarding core fets; verticals específics pendents) |
| 14 | Employees (RRHH bàsic) | ✅ |

## 5.2 Ordre recomanat (Fase a Fase)

### Fase A — Tancar la base
1. ✅ **Locations & Assets** (genèric, ràpid).
2. ✅ **Calendari genèric** (depèn de tenants/sites/contacts → però es pot fer
    sense Contact i lligar després).
3. ✅ **Jobs/Events/Notifications worker** (PGMQ + Edge Function).

### Fase B — La capa universal de negoci
4. ✅ **Contacts** + **ContactSites** (peça crítica). Inclou validació de
   `metadata` per JSON Schema.
5. ✅ **Catalog** (`catalog_items` products + services) + `project_lines`.
   Desbloqueja pressupostos, tarifaris i taller fabricant.
6. 🟡 **Industry Archetypes + Verticals + onboarding wizard**.
    Implementat: archetypes base + onboarding wizard core.
    Pendent: verticals específics i més receptes sectorials.
    Aquí el producte fa el "click" sectorial. Vegeu
   [03-sector-profiles.md](03-sector-profiles.md) per la taxonomia.

### Fase C — Recordatoris i comunicació activa
7. 🟡 **Communications outbound** (email ja → afegir SMS i WhatsApp).
8. 🟡 **Recordatoris automàtics** sobre CalendarEvents (pipeline i worker ja implementats per email; pendent ampliar canals).
9. **Inbox unificat** (V1 simple: log de comunicacions per Contact).

### Fase D — Mòduls verticals (en paral·lel un cop B+C llestos)
10. **Field Service / Work Orders** (arquetip `field_service`, també
    reutilitzat per `workshop_maker` quan va a camp) — reaprofita Projects
    + Catalog.
11. **Clinical / Professional Records** (arquetip `practice`) — reaprofita
    DMS + Contact metadata. L'addon es declina per vertical: `clinical`
    (dentista, fisio, vet, metge…), `legal` (advocat, gestoria), `coaching`
    (psicòleg, nutricionista).
12. **Reserves / Booking horari** (arquetip `hospitality`) — reaprofita
    Calendar + Locations (taules) + Assets amb `capacity`.
13. **HR bàsic** (Employee, contractes, documents). Crític per
    `hospitality` i `lodging`; útil arreu.
14. **Stock-lite + manteniments preventius** (arquetip `workshop_maker`) —
    recurrència de CalendarEvents lligats a Assets venuts
    (`contact_site_id`).

### Fase D-bis — Arquetips V2 (un cop validats els 4 de V1)
14b. **`lodging`** — booking multi-dia (rang de dies, no slots),
    `cleaning_block` automàtic entre estades, gestió documental amb
    escaneig de DNI/passaport, càlcul de taxa turística. Possibles
    addons V2.5: `channel_manager` (Booking/Airbnb), `tourist_tax`. Reusa
    Calendar + Assets (habitacions/parcel·les) + DMS, no requereix codi
    nou més enllà del booking multi-dia i el bloqueig d'Asset per rang.
14c. **`appointment_walkin`** — cua de walk-in + cites curtes amb
    "qui ha atès" visible. Reusa Calendar + Employees.

### Fase E — Diferenciació
15. **IA assistents per sector** (vegeu doc 07).
16. **Integracions premium** (vegeu doc 06).
17. **Portal client lleuger** (share_links → V2 amb magic link si demanda).
18. **Facturació al final-client** (integració amb facturació externa o
    mòdul propi mínim).

## 5.3 Criteris per "moure" un mòdul de fase

- Tenir validació amb 3 usuaris reals del sector destinatari.
- Auditoria implementada des del dia 1.
- i18n complet (català mínim, castellà desitjable).
- Mobile-first verificat.
- No afegir un mòdul que requereixi modificar dependències ja tancades.

## 5.4 Què deixem explícitament al calaix (V1)

- Comptabilitat doble partida.
- Inventari amb rotació/lots.
- BPM/Workflows configurables.
- Marketplace d'addons de tercers.
- App mòbil nativa (PWA primer).
- White-label complet per partner.
