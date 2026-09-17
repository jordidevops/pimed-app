Field Management Service (FSM)

Volt Serveis es queda com l’autònom (Alice ho fa tot).

### Riera Instal·lacions (PIME)
Tots amb password `Test1234!`

| Persona | Email | Rol | Paper |
|---|---|---|---|
| Gina Riera | `gina@riera-instal.com` | owner | Oficina: crea ordres, catàleg, comercial |
| Hèctor Soler | `hector@riera-instal.com` | member | Tècnic de camp |
| Inés Vidal | `ines@riera-instal.com` | member | Tècnica de camp |

Hi ha dues ordres d’avui: caldera (Hèctor) i clima (Inés).

### Entrada a l’app (`field_service`)
- **Member/viewer:** sempre `/field/today`, també a escriptori.
- **Owner/manager:** per defecte `/field/today` al mòbil i `/dashboard` a pantalla gran (`lg` ≥ 1024px).
- Ho poden canviar a **Pantalla d’inici**: automàtica, sempre Avui o sempre Inici (a l’Inici i a Més).

Alice a Volt, a escriptori, ja entra a Inici i pot obrir Avui des del menú. Ho he comprovat al portal local.

### UI limitada dels tècnics
Els `member` no veuen mòduls d’oficina (empleats, catàleg, pressupostos, configuració, plantilles…). A **Més** els queda el que necessiten al camp: fitxatge, clients i preferències del dispositiu.


DocuSeal

- El correu "Tu copia del documento" l'auriem d'enviar nosaltres?
- Al centre de firmes que quedi clar els dies passats sense firmar i si està una firma marcada com revisada.
- Provar la firma amb pdfs sense camps de firma i amb camps de firma.


Plantilles

- A crear o editar plantilles docx que es pogui fer al frontend
- A tenant-portal crear nova plantilla surt per posar "Sector objectiu (opcional)" i Verticals sectorials (opcional). Això només a admin-portal
- Clonar una plantilla que copiï al storage del tenant el docx
- Si el feature flag de signar està desactivat no ha de sortir l'opció o estar desactivada.

Plantilles comercials (`docs/plans/commercial-templates/`) — pendent un cop tanquem aquest pla

- **Fase 4 de `docs/plans/signing/pla_alineacio_firmes_docuseal_native.plan.md`** (mode d'evidències `native_evidence_mode` + Admin UI, extracció de `signing_field_map` en generar el PDF signable, branca `detached`/`embedded`/`both` a `stamp-pdf-signatures`, fallback `buildDefaultSignatureFields`): a data 2026-09-17 el propi pla la marca sense fer. Bloqueja QT-9 (pipeline de firma) del pla de plantilles comercials — no cal completar-la abans de QT-0…QT-8, però sí abans d'obrir QT-9.
- Fase 2 del pla de plantilles comercials (DOCX): estendre `scripts/generate-docx-seed.mjs`, validar/reutilitzar el pipeline docx→pdf per a documents comercials (QT-6/QT-7).
- Implementació del contracte signat post-acceptació de pressupost — només dissenyat a `05-contract-signing-forward-compat.md`, sense epic obert.
- Facturació fiscal pròpia — només nota forward-compat a `05-contract-signing-forward-compat.md` § 7, sense dissenyar.
- Verificar durant QT-2/QT-6 si Docxtemplater resol camins amb punt (`[[tenant.name]]`) o cal aplanar claus al context.
- Verificar durant QT-9 si `sign-document-router` amb `source_type='document_existing'` localitza els tokens `[FIRMA:role]` en un PDF que no prové d'un `document_template_locales` (generat per `render-commercial-document`).

Per validar manualment: obre un projecte amb site_id no nul → activa "Offline" a DevTools Network → clic "Simular check-in" → comprova la consola de Dexie (Application > IndexedDB) → desactiva offline → l'op passa a synced i apareix server_id guardat.


Cues
 - Estratègia de fairness per tenant a les cues. No volem que un tenant acapari tota la cua enlantint el processos dels altres. Cal fer un sistema just i que beneficiï a tenants amb plans superiors.


## Plan: Continuació Implementació Q2

Recomanació clara: continueu per tres vies, en aquest ordre de dependència:
1. Employees (bloquejador funcional)
2. Public Portal Sprint 1-2 (en paral·lel)
3. Time Attendance foundation (just després d’Employees)

Això aprofita que la base ja està molt madura i evita obrir verticals sense fonaments.

**Per què aquesta prioritat**
1. L’estat real ja complet de base de plataforma és alt a 10-implemented-modules.md: core multi-tenant, RLS, DMS, email, calendar, PGMQ.
2. El roadmap marca explícitament Employees com no començat i verticals/comunicacions com parcials a 05-modules-roadmap.md.
3. El Public Portal ja té pla executable setmanal molt concret a 12-public-portal-sprint-plan.md, així que és ideal per avançar en paral·lel sense esperar-ho tot.

**Steps**
1. Fase 1: Employees (setmana 1)
2. Fase 2: Public Portal Sprint 1-2 en paral·lel (setmanes 1-2)
3. Fase 3: Time Attendance foundation (setmanes 2-3, depèn de Fase 1)

**Detall per fase**
1. Fase 1: Employees
- Incloure model mínim RRHH (employee vinculat a tenant/site, opcionalment a user).
- Tancar RLS i permisos de lectura/escriptura per rols.
- Tancar auditoria de cicle de vida.
- Sortida esperada: backend foundation de persones operatives per horari i payroll.
2. Fase 2: Public Portal Sprint 1-2
- Sprint 1: contracte i model SQL amb auditoria.
- Sprint 2: RLS, vistes api i RPCs de lifecycle.
- Sortida esperada: nucli segur i publicable del portal públic, sense dependència forta de frontend final.
3. Fase 3: Time Attendance foundation
- Implementar model de fitxatges, intervals i resum diari.
- Implementar RPCs de registre/sync i recomputació asíncrona.
- Sortida esperada: base tècnica de fitxatge preparada per UI i pilot.

**Relevant files**
- 10-implemented-modules.md — font de veritat del que ja existeix.
- 05-modules-roadmap.md — priorització de fases i estat parcial/no començat.
- 12-public-portal-sprint-plan.md — execució per sprints de Public Portal.
- 14-time-attendance-overview.md — abast funcional de control horari.
- 15-time-attendance-architecture.md — patrons d’arquitectura i sincronització.
- 16-time-attendance-data-model.md — contracte de model SQL.

**Verification**
1. Fase 1 validada quan Employees existeix amb RLS i auditoria en staging.
2. Fase 2 validada quan Public Portal Sprint 1-2 té taules, polítiques i RPCs operatives.
3. Fase 3 validada quan el registre de fitxatges és idempotent i la recomputació diària passa per cua asíncrona.

**Scope boundaries**
- Inclòs ara: foundation de dades, seguretat i lifecycle.
- Exclòs ara: polish UX complet, verticals avançats (field service/booking), payroll complet i canals extra (SMS/WhatsApp).

Si vols, et preparo immediatament el desglossat de tasques d’implementació de la Setmana 1 (issues tècniques concretes i ordre de migracions) perquè l’equip pugui començar avui.




Read [](file:///c%3A/JordiDevops/app-supabase/docs/product-design/03-sector-profiles.md#1-1), lines 1 to 150

La teva pregunta és absolutament estratègica. Anem a la resposta directa i després a l'explicació del pla.

**L'enfocament correcte és: PRIMER el frontend genèric (Core Admin/Settings) i DESPRÉS el primer vertical.**

No s'ha d'intentar construir una "sala d'espera de fisioteràpia" (vertical) sense abans poder crear "sales" (Locations) i "fisioterapeutes" (Employees). El vertical és només una "recepta" (labels, esquemes JSON, botons per defecte) que s'aplica sobre el motor genèric.

### Per què aquest enfocament? (El Rationale)

1. **Dependència arquitectònica**: Ahir a la diagnosi vam veure que tota la base SQL està molt madura (Departments, Locations, Contacts, Calendar). Però si l'usuari no té una pantalla genèrica on crear les seves `Locations` de forma crua i assignar permisos als `TenantMembers`, cap flux vertical funcionarà sense fer trampes ("hardcoding" dades).
2. **Economia de codi**: El projecte ja defineix als documents que els arquetips són *declaratius* (un JSON amb "labels" i "receptes"). Si banyes la UI del frontend amb codi específic del vertical des del minut 1, trencares la promesa multi-vertical i hauràs de refer codi cada cop que un sector nou entri.
3. **Escalabilitat ràpida**: Si la pantalla genèrica permet crear `Assets` (béns), el `field_service` ho usarà per furgonetes, l'`hospitality` per taules i el `workshop_maker` per maquinària. Tot provinent del mateix component React genèric.

### Quan podrem tenir l'arquetip funcional? (El Pla)

Si portem l'execució ben enfilada, **en 4 setmanes** (1 mes) podem tenir el primer pilot sectorial girant. L'ordre seria aquest:

*   **Setmana 1: "Peça Central" (Employees + Settings Genèrics)**
    *   Backend: Completar la prioritat d'`Employees` (RRHH base).
    *   Frontend: Crear el Dashboard d'Admin (on l'usuari pot convidar gent, crear els departaments i fer el CRUD bàsic de localitzacions). Et donarà una aplicació "Lego" funcional.
*   **Setmana 2: Motor Arquetípic (Aplicar la Recepta)**
    *   Backend: Consolidar les taules `industry_archetypes` i `industry_verticals` (que estan a 03-sector-profiles.md).
    *   Frontend: L'Onboarding Wizard. L'usuari entra, diu "Sóc fontaner" i l'app injecta la configuració de `field_service` adaptada (crea plantilles per defecte, renombra "Client" en lloc d'altres paraules, pre-crea tasques genèriques).
*   **Setmana 3: Primera Capa Especialitzada (Vertical UI)**
    *   Ara sí: Escolliu el *primer vertical* (recomano `field_service` perquè aprofita Molt el motor documental i poc de calendari complex).
    *   Frontend: Pantalla/Vista filtrada dissenyada EXCLUSIVAMENT per facilitar el flux daquest arquetip. Exemple: un "taulell de despatxos diaris" consumint l'API de projectes i tasques genèriques.
*   **Setmana 4: Control horari (Time Attendance)**
    *   Inserir el Time Attendance i encendre la part d'Employees. Aquí la roda està tancada.

**Recomanació:**

Fes la interfície de configuració genèrica PRIMER. Si t'hi animes, aquesta setmana mateix ataca la base d'`Employees` (backend) alhora que deixes el CRUD de `Locations` al portal Tenant apunt. Després, quan tinguis la infraestructura base sòlida visible, el primer vertical caurà sola com una pell ("reskin") UI per sobre.

# tenant-portal


- Si editem una plantilla de layout base no arriba el correu amb la modificació
- Mostrar al perfil el rol de l'usuari
- Fitxers no mostra la capacitat segons pla
- Fer que Drive contempli el multi-site
- Un tenant no ha de poder afegir el doomini de la startup. A "Registres DNS per verificar" que es pogui copiar els valors per evitar errors.
- S'ha de poder desactivar en un tenant que pogui afegir dominis. Al pla free de Resend només admet un custom domain, al pla pro 10. Veure carpeta de prompts.
- Revisar si caiem en l'infern del RLS Polimòrfic.

Veriifcar els members i sites que poden gestionar els clients.

Al afefegir un domini d'email, si hi ha error per api key encara es crea el domimi a Postgres, però només es veu al actualitzar.

Integrar el storage avatar a public-assets.

# admin-portal

-----------------------
DONE
Tal com ho veig per un sistema de plantilla base de correus ha de tenir aquest fluxe de fallback:
Plantilla de correu (PC) -> Plantilla base del tenant (PBT) -> Plantilla base de la startup (PBS)
 La plantilla PC és la que es passa per clau, id, etc a la funció de processament d'email amb les etiquetes subtitutives i els seus valors. També es passa un flag sobre si cal utilizar una plantilla base com a wrapper de PC. Si és que sí es busca PBT i si existeix s'aplica. Si no hi ha PBT s'aplica PBS.
 Un altre tema són les plantilles PC. El tenant pot crear i configurar les seves plantilles que es guardaran la la taula email_templates. No obstant la starup proporciona un repositori de plantilles (PDef) que es guarden a default_email_templates o similar, agupades per móduls i procediments. Per a determinats móduls o precediments tindrem que aquests estan associats a una plantilla de la startup, però el tenant pot editar aquesta plantilla i guardar-la entre les seves.
---------------------




És possible i segur que des de l'admin-portal tinguem un sistema de backups propi? Supabase en la versió free no proporciona backups per tant com a mínim poder fer i descarregar backups o guardarlos en el propi Storage de Supabase, en aquest cas hauriem de saber quan ocupen. també l¡opció d'enviar-los a un storage R2 de Cloudflare i idealment un cron job que els faci periodicament. És possible una solució custom i pròpia de backups dins l'entorn Supabase? Estudiem-ho, parlem-ne abans de fer un prompt per implementar-ho.



Drive
R2 Cors Policy


[
  {
    "AllowedOrigins": ["http://localhost:5173"],
    "AllowedMethods": ["GET", "PUT", "HEAD", "DELETE"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag", "Content-Length"],
    "MaxAgeSeconds": 3600
  }
]




Què cal fer ara per provar el password reset?

Configurar la Secret: A la terminal, hauràs d'activar el registre públic amb:
supabase secrets set PUBLIC_SIGNUP_ENABLED=true

Configurar les URLs: A Supabase Dashbord (Authentication > URL Configuration), recorda posar el teu tenant-portal com a Site URL.

Provar el flux: Crea un usuari des de l'admin-portal i verifica que arriba el correu, que pots posar la contrasenya a /auth/reset-password i que, un cop dins, la teva taula profiles marca el first_login_at.