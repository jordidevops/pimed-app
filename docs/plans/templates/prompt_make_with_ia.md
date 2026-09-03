# Prompt per a la IA implementadora

Tens accés complet al codi del repositori. Adjunt trobaràs:
- `make_templates_with_ia_v2.md` — pla del "Centre de Confecció de Plantilles amb IA".
- `03-sector-profiles.md` — model d'Arquetips i Verticals (perfils sectorials de tenant).

## Objectiu

Revisar el pla de plantilles amb IA i ampliar-lo amb una funcionalitat nova: **suggeriments de prompts predefinits**, contextualitzats per **mòdul de l'app** (Empleats, Contactes, Projectes, etc.) i pel **perfil sectorial del tenant** (arquetip + vertical, segons `03-sector-profiles.md`).

## Requisit funcional

Dins del "Template AI Wizard" (Pas 1), abans/junt amb el prompt genèric editable, l'app ha de mostrar una llista de **suggeriments de plantilles rellevants** per al tenant actual, en forma de prompts ja redactats i llestos per usar (l'usuari els selecciona, opcionalment els edita, i els copia/usa per generar el JSON amb la IA externa).

### 1. Catàleg de suggeriments
- Crear un catàleg (seed, similar en esperit a `templates_seed`/`catalog_seed` d'`industry_verticals`) de "plantilles suggerides", cadascuna amb:
  - Mòdul/àmbit (`employees`, `contacts`, `projects`, etc. — revisar quins mòduls/addons existeixen realment al codi).
  - Arquetip(s) i/o vertical(s) als quals aplica (pot ser genèric a tots, específic d'un arquetip, o específic d'un vertical concret).
  - Títol curt i descripció breu (què és la plantilla, per mostrar a la UI com a "card").
  - El **text del prompt** a injectar al Wizard (pot reutilitzar el mecanisme de generació de prompt ja dissenyat al pla de plantilles amb IA: rols de sistema, esquemes d'entitat, instruccions sobre blocs, etc., més una descripció específica del cas d'ús).
- Decidir si aquest catàleg viu com a taula nova (`data.template_ai_prompt_suggestions` o similar) o com a part de `industry_archetypes`/`industry_verticals` (camp `templates_seed` ja existent). Avaluar pros/cons:
  - Taula pròpia: més flexible per a cerca/filtratge i per afegir suggeriments sense tocar el catàleg sectorial.
  - Dins `templates_seed`: coherent amb la resta de seeds per vertical, però `templates_seed` sembla pensat per a plantilles ja fetes, no per a "prompts suggerits".

### 2. Resolució de suggeriments per al tenant
- A l'obrir el Wizard (o a una vista prèvia tipus "galeria" dins `/documents/templates`), calcular els suggeriments aplicables:
  - Suggeriments **genèrics** (vàlids per a tots els tenants/mòduls).
  - Suggeriments de l'**arquetip** del tenant (`tenant_sector_config.archetype_id`).
  - Suggeriments del **vertical** del tenant (`tenant_sector_config.vertical_id`), si n'hi ha de més específics.
  - Aplicar la mateixa lògica de capes que `config_efectiu` (§3.4 de `03-sector-profiles.md`): vertical pot afegir o refinar suggeriments respecte a l'arquetip, no cal que els llisti tots de nou.
- Si el tenant no té `tenant_sector_config` (o és `generic`), mostrar només els suggeriments genèrics.

### 3. Exemples de suggeriments per mòdul (la IA ha de generar-ne un conjunt real, no placeholders)
Generar com a mínim suggeriments per a:
- **Empleats/RRHH** (genèric i per arquetips amb RRHH formal: `practice`, `hospitality`, `workshop_maker` segons la taula de §3.3): contracte laboral, NDA, full d'incorporació, avaluació de període de prova.
- **Contactes/Clients**: full d'alta de client, consentiment de tractament de dades (RGPD), pressupost/oferta.
- **Projectes/Treballs**: comanda de treball (`workshop_maker`), full de servei/intervenció (`field_service`), full d'admissió/expedient inicial (`practice`).
- **Específics de vertical** (almenys 2-3 exemples concrets, ex: `dentist` → full de consentiment informat tractament dental; `restaurant` → full de reserva d'esdeveniment privat; `electrician` → pressupost d'instal·lació elèctrica).

Cada suggeriment ha d'incloure el text de prompt complet i coherent amb el format de prompt ja definit a `make_templates_with_ia_v2.md` (incloent-hi la injecció de rols/variables d'entitat i la instrucció sobre blocs de headers/footers si aplica).

### 4. UI
- A `/documents/templates`, en crear una plantilla nova (o dins el Wizard), mostrar una secció "Suggeriments per al teu negoci" amb cards dels prompts suggerits filtrats segons el punt 2.
- Seleccionar una card omple/obre el Wizard amb el prompt corresponent ja generat (combinant el text base del suggeriment amb el context dinàmic del tenant — rols, entitats — igual que la resta de prompts del Wizard).
- Permetre també una vista "explorar tots" (no filtrada) per si el tenant vol idees d'altres sectors.

## Instruccions de revisió (per a la IA implementadora)

1. **Revisar l'estat real de `03-sector-profiles.md`** al codi: confirmar si `industry_archetypes`, `industry_verticals` i `tenant_sector_config` ja existeixen com a taules, o si encara és disseny pendent. Si és pendent, aquesta funcionalitat de suggeriments pot dependre d'aquest treball previ — deixar-ho explícit al pla detallat i proposar un fallback (ex: només suggeriments genèrics) si encara no hi ha dades sectorials.
2. **Inventariar els mòduls/addons reals** de l'app (no assumir `employees`/`contacts`/`projects` literalment) per mapejar correctament els suggeriments.
3. **Decidir l'estructura del catàleg de suggeriments** (taula nova vs. extensió de `templates_seed`), tenint en compte el sistema de `seed_version` (§3.11) si es vol poder actualitzar suggeriments sense afectar tenants existents.
4. **Reaprofitar el generador de prompt** del pla `make_templates_with_ia_v2.md` (Fase 2.2): els suggeriments no haurien de duplicar la lògica de context (rols de sistema, esquemes d'entitat, flag de blocs headers/footers), només afegir la "intenció"/cas d'ús específic per damunt.
5. **Idempotència i governança**: si el catàleg de suggeriments es versiona per vertical igual que `templates_seed`/`catalog_seed`, seguir el mateix patró d'actualització opcional descrit a §3.11 (el tenant decideix si vol "refrescar" suggeriments nous).
6. **Verticals fora de V1**: `03-sector-profiles.md` indica que V1 implementa només `field_service`, `practice`, `hospitality`, `workshop_maker`, `generic`. Generar suggeriments com a mínim per a aquests 5 arquetips; `lodging`/`appointment_walkin` (V2) poden quedar com a esborrany o ometre's.

## Entregables esperats

1. Pla detallat d'implementació (estructura de dades del catàleg, punts d'integració amb el Wizard, components UI).
2. Implementació del codi corresponent.
3. Seed real de suggeriments (textos de prompt complets, no placeholders), cobrint els mòduls i arquetips/verticals indicats al punt 3.
4. Resum final de decisions preses on hi hagi marge d'interpretació (especialment l'estructura del catàleg, punt 1).