# Estudi i Pla d'Implementació: Headers, Footers i Blocs en Plantilles de Documents

## 1. Visió General de la Proposta
L'objectiu és proveir a les plantilles de documents (tant **HTML** com **DOCX**) d'un sistema estandarditzat per incloure encapçalaments, peus de pàgina, i altres fragments de contingut reusable, de manera que:
1. S'utilitzin etiquetes especials a la plantilla (ex: `{{ header_block }}` per HTML, `[[ header_block ]]` per DOCX).
2. Es puguin crear i gestionar "Blocs de Contingut" de forma centralitzada al tenant o site.
3. Es permeti seleccionar i desar l'assignació d'aquests blocs directament a la pantalla d'edició/ús de la plantilla de document.
4. Aquests blocs de contingut també tinguin accés a dades globals (com el nom del tenant o del site).

---

## 2. Estudi de Viabilitat segons el Format

El repte principal rau en la disparitat de les tecnologies utilitzades per renderitzar els dos formats de document.

### 2.1. Plantilles HTML (LiquidJS)
* **Com funciona actualment:** S'utilitza `LiquidJS` per renderitzar HTML i després Gotenberg per passar-ho a PDF.
* **Viabilitat:** **Molt Alta**.
* **Mecanisme de substitució:** Injectar un fragment d'HTML provinent d'un "Bloc" en una variable `{{ header_block }}` és completament natiu. L'únic requeriment per al bloc és que, abans de ser injectat a la plantilla final, també ha de ser renderitzat per LiquidJS perquè les etiquetes globals (`{{ tenant.name }}`) s'hi interpretin.

### 2.2. Plantilles DOCX (Docxtemplater)
* **Com funciona actualment:** S'utilitza `Docxtemplater` i després Gotenberg (LibreOffice) per a convertir-ho a PDF si s'escau.
* **Viabilitat:** **Mitjana-Alta (amb condicions estructurals)**.
* **Mecanisme de substitució:** `Docxtemplater` analitza automàticament els headers i footers natius del fitxer Word, així que es pot posar l'etiqueta `[[ header_block ]]` dins la capçalera nativa de l'arxiu DOCX. 
* **Limitació important:** La versió base de Docxtemplater substitueix la variable per **text pla**, no per HTML ni sub-documents. Per tant:
  * Si el "Bloc de Contingut" assignat conté només text pla (ex: text legal, adreces), funcionarà perfectament en DOCX.
  * Si es vol injectar una taula complexa o imatges a la capçalera de DOCX, s'haurà de dissenyar nativament al mateix document Word base, deixant exclusivament l'ús d'etiquetes globals genèriques (ex: `[[ tenant.name ]]`) directament a la plantilla sense fer ús d'un "Bloc HTML".

---

## 3. Arquitectura del Sistema de Blocs

### A. Model de Dades
S'haurien de crear o modificar les següents taules:

1. **`document_content_blocks`** (Nova Taula):
   - `id` (uuid)
   - `tenant_id` (uuid)
   - `name` (string) - Nom descriptiu ("Peu legal estándar").
   - `block_type` (enum) - `HEADER`, `FOOTER`, `CUSTOM`.
   - `format` (enum) - `HTML`, `TEXT`.
   - `content` (text) - El contingut pròpiament dit.
   - `created_at`, `updated_at`.

2. **`document_templates`** (Modificació Taula Existent):
   - Afegir la columna `default_block_mapping` (jsonb). Estructura suggerida: `{"header_block": "uuid-del-bloc", "footer_block": "uuid-del-bloc"}` per poder desar les opcions per defecte i no haver de seleccionar-les contínuament cada cop que s'usa.

### B. Gestió de Variables Globals (Context Builder)
Al fitxer central de creació de context (`supabase/functions/_shared/context-builder.ts`):
- Injectar automàticament un sub-objecte `tenant` i/o `site` per a totes les operacions de generació:
  ```json
  {
    "tenant": {
      "name": "Nom del Tenant",
      "address": "Carrer...",
      "logo_url": "https://..."
    }
  }
  ```

---

## 4. Pla d'Implementació Pas a Pas

### Fase 1: Creació del Model de Dades i Variables Globals
1. **Migracions SQL**:
   - Crear taula `document_content_blocks` amb RLS (Row Level Security) per aïllar dades per `tenant_id`.
   - Afegir camp JSONB `default_block_mapping` a la taula `document_templates`.
2. **Context Builder Backend**:
   - Modificar l'endpoint d'API / worker de generació de documents (`sign-document-router`) per incloure sempre les dades bàsiques del `tenant` dins del `context` genèric, i així siguin accessibles pels motors de `liquid-renderer` i `docx-renderer`.

### Fase 2: Gestió UI de Blocs (Settings)
1. **Settings de l'Aplicació (Tenant Portal)**:
   - Crear un nou apartat sota `/settings/documents` o similar anomenat "Blocs de Contingut".
   - UI amb Taula on es llisten els blocs disponibles per tipus i format.
   - Modal/Pàgina per Crear i Editar Blocs. Per HTML es mostrarà un Editor Richtext o Editor Codi HTML. Per blocs Text, un Textarea simple.

### Fase 3: Edició i Selecció a les Plantilles de Documents
1. **UI de Plantilles (`TemplateFormModal` / `TemplateDetailPage`)**:
   - Afegir un nou panell d'assignació: "Configuració de Blocs (Headers/Footers)".
   - Aquesta secció permet mapejar etiquetes específiques (com `header_block` i `footer_block`) cap a qualsevol `document_content_block` existent de l'entorn.
   - Desar el mapeig seleccionat dins el nou camp `default_block_mapping`.

### Fase 4: Integració de Renderitzat
1. **Preparació prèvia a la renderització**:
   - A `sign-document-router.ts`: Quan es procedeix a renderitzar, l'API ha de llegir `default_block_mapping`.
   - S'extreuen de la BD els `content`s dels blocs requerits.
   - Per l'opció de blocs dinàmics, es pre-renderitzen els blocs passant-los el context (per si contenen `{{ tenant.name }}`).
   - Finalment s'injecten com a variables estandard en l'arbre del `context` final (ex: `context.header_block = "<html>...</html>"`).
2. **Execució dels Motors**:
   - Tant `LiquidJS` com `Docxtemplater` substituiran les variables com ho fan de costum.

---

## 5. Cas d'Ús: Exemple de Flux de Treball

1. L'usuari va a "Blocs de Contingut" i crea el bloc "Peu Legal DOCX", de tipus *Text*, que conté: `Document generat per [[ tenant.name ]]. Tots els drets reservats.`
2. Descarrega la seva plantilla de Word i afegeix al peu de pàgina l'etiqueta `[[ footer_block ]]`.
3. Al Tenant Portal, obre els detalls de la Plantilla de Word i a l'apartat "Assignació de blocs", diu que `footer_block` va lligat al bloc "Peu Legal DOCX".
4. En el moment de processar el document, l'API construeix el context amb la informació del tenant i avalua el bloc.
5. El fitxer Word resultant incorpora perfectament el text legal amb el nom corresponent al peu de pàgina de cada plana.
