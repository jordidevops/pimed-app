# 1. Visió i posicionament

## Qui és l'usuari

Dos arquetips, mateixa plataforma:

### Tier A — "Solo" (1-3 persones)
- L'**autònom** o **empresari individual** amb com a molt 1-2 ajudants o un
  aprenent.
- Ell mateix és owner, comercial, tècnic i administratiu.
- L'eina ha de ser **brutalment simple**, sense conceptes corporatius
  (departaments, jerarquies). Mòbil al 90%.
- Exemples: electricista autònom, fisioterapeuta, perruquer a domicili,
  consultor.

### Tier B — "Micro" (4-20 persones)
- Petites empreses amb **una mica d'estructura**: un cap, alguns operaris,
  potser una persona d'oficina.
- Necessiten rols diferenciats, agenda compartida, una mica de RRHH.
- Encara odien la complexitat dels ERP "de veritat".
- Exemples: clínica dental, restaurant petit-mitjà, **taller petit que
  fabrica/repara i fa servei a camp**, immobiliària de barri, gimnàs.

### Comú a tots dos
- Perfil tècnic baix-mitjà. No volen "configurar un ERP".
- Treballen molt **fora de l'oficina** (mòbil, tauleta).
- Pocs clients en valor però alta freqüència de contacte i operació.
- Onboarding ha de ser autoservei: si necessiten consultor, els hem perdut.

## Què odien dels ERP/CRM actuals

| Dolor | Conseqüència de disseny per a nosaltres |
|---|---|
| "Demana 3 mesos d'implementació" | Onboarding sectorial guiat < 5 min. |
| "Té 200 camps i n'uso 5" | UI condicionada al sector + camps ocults per defecte. |
| "Per fer X he de saltar entre 4 pantalles" | Vistes 360° per entitat (timeline contacte). |
| "El mòbil és una versió retallada" | El mòbil és la vista primària de camp. |
| "Cada integració costa una fortuna" | Catàleg d'integracions amb activació 1-clic. |
| "Si vull canviar res, em diu el comercial" | Configuració per perfil sectorial editable pel propi tenant. |

## Els 4 arquetips d'arrencada (validació)

> Els noms d'oficis (electricista, dentista, restaurant, taller) que apareixen
> a continuació són **exemples concrets per validar cada arquetip**, no
> categories tancades del producte. La taxonomia oficial és:
> **arquetip → vertical → tenant**, definida a
> [03-sector-profiles.md](03-sector-profiles.md).

1. **`field_service`** *(Tier A o B)* — validem amb electricista autònom
   (+ verticals: lampista, persianista, fontaner, climatització, jardiner,
   neteja, antenista, instal·lador solar…). Treball al lloc del client.
2. **`practice`** *(Tier B)* — validem amb clínica dental (+ verticals:
   fisioterapeuta, podoòleg, psicòleg, metge, veterinari, advocat,
   gestoria…). Local propi + cita programada + expedient.
3. **`hospitality`** *(Tier B)* — validem amb restaurant (+ verticals: bar,
   cafeteria, hotel petit, casa rural). Servei al públic + reserves +
   plantilla operativa.
4. **`workshop_maker`** *(Tier B)* — validem amb taller petit fabricant
   (+ verticals: fusteria, serralleria, taller mecànic, vidrieria, taller
   bicis, retolació…). Producció + venda + servei postvenda.

Quatre arquetips amb patrons de negoci radicalment diferents (servei pur,
salut/professional, hostaleria, manufactura lleugera) → si la mateixa base
els cobreix, podem afegir desenes de verticals **sense tocar codi**.

### Per què el `workshop_maker` és l'arquetip que més estressa la base

És el que aporta requisits que els altres tres no:
- Catàleg de **productes propis** (no només serveis).
- Estoc lleuger de producte acabat (no MRP, no lots).
- **Cicle de vida client llarg**: venda → instal·lació → garantia →
  manteniments recurrents → recanvis. Tot el mateix `Contact`.
- Pressupostos i comandes amb línies de catàleg.
- Treball mixt taller (Locations internes) + camp (al ContactSite del client).

Si la base ho aguanta de forma natural (sense codi específic), tenim
certesa que aguantarà tot el ventall objectiu.

## Promesa de producte

> "Tria què fas. En 3 minuts tens l'agenda, els clients i els recordatoris
> automàtics funcionant. Des del mòbil. Sense configurar res."

## El que **no** som

- No som un ERP fiscal/comptable complet (Holded, Sage). Integrem.
- No som un POS (Point of Sale: Square, Glovo). Integrem.
- No som una eina de màrqueting massiu (Mailchimp). Integrem.
- No som una agenda de booking públic com a producte principal (Calendly), tot
  i que la nostra agenda té funcions de booking.

Aquest "no" és tan important com el "sí": evita que la base es contamini.
