# Context

En la nostra una plataforma SaaS multi-tenant basada en Supabase, actualment disposem de dos sistemes de plantilles:

## 1. Plantilles de correu

Característiques:

* HTML + text pla.
* Multiidioma mitjançant locales.
* Layouts reutilitzables.
* Variables amb sintaxi:

```html
{{full_name}}
{{company_name}}
```

* Actualment disposem d'una implementació pròpia de condicionals basada en:

```html
{{#if full_name}}
  Hola {{full_name}}
{{/if}}

{{#unless full_name}}
  Hola usuari
{{/unless}}
```

* El renderitzat es realitza principalment dins Edge Functions de Supabase (Deno) process-email-queue i sign-document-router,
i dins d'elles els condicionals en les funcions renderConditionals() i renderDocumentConditionals().
* També existeixen previsualitzacions al frontend.

## 2. Plantilles de document

Formats suportats:

* DOCX
* HTML

Actualment les variables DOCX utilitzen:

```text
[[full_name]]
[[company_name]]
```

Cada locale de la plantilla guarda un `variables_schema`:

```json
{
  "full_name": {
    "role": "worker",
    "type": "string",
    "label": "Nom del treballador/a",
    "order": 0,
    "required": true
  }
}
```

I també un `signing_roles_schema`:

```json
{
  "worker": {
    "label": "Treballador/a",
    "order": 0,
    "entity_type": "employee",
    "for_signing": true
  }
}
```

Durant la generació del document:

* Cada rol es vincula a una entitat real.
* Les dades de l'entitat omplen les variables.
* Existeixen camps de signatura compatibles amb DocuSeal.
* El sistema permet definir múltiples rols signants.

# Objectiu

Volem substituir els motors propis de processament de plantilles per solucions estàndard i més potents.

## Emails i HTML

Utilitzar LiquidJS.

Exemples desitjats:

```liquid
{{ full_name }}

{% if full_name %}
Hola {{ full_name }}
{% endif %}

{% unless full_name %}
Hola usuari
{% endunless %}

{% for item in items %}
{{ item }}
{% endfor %}
```

## Documents DOCX

Utilitzar Docxtemplater.

Restricció obligatòria:

* Les variables han de continuar utilitzant delimitadors `[[ ]]`.
* Docxtemplater s'ha de configurar perquè treballi amb delimitadors personalitzats `[[ ]]`.

Exemples:

```text
[[full_name]]

[[#employees]]
[[name]]
[[/employees]]
```

Volem aprofitar condicionals, loops i funcionalitats natives de Docxtemplater en lloc de mantenir codi propi.

# Fitxers adjunts

He adjuntat fitxers reals del projecte perquè puguis analitzar la implementació actual minimitzant els tokens consumits:

* Edge Function `process-email-queue`
* Frontend `EmailTemplateEditor.tsx`

També s'hauran de revisar altres components relacionats com:

* sign-document-router
* editor de plantilles de document
* previsualització de documents
* serveis de generació de documents

# Restriccions arquitectòniques

Aquestes decisions ja estan preses i no s'han de qüestionar:

## Emails

* LiquidJS serà el motor oficial.
* Les variables continuaran utilitzant `{{ variable }}`.
* Els condicionals i bucles utilitzaran sintaxi nativa Liquid.

## DOCX

* Docxtemplater serà el motor oficial.
* Les variables continuaran utilitzant `[[variable]]`.
* No volem utilitzar `{variable}`.
* Docxtemplater s'ha de configurar amb delimitadors `[[ ]]`.
* Les etiquetes de signatura compatibles amb DocuSeal s'han de continuar suportant.

## General

* No volem mantenir motors propis de condicionals.
* No volem implementar parsers propis.
* Volem delegar el màxim possible en LiquidJS i Docxtemplater.

# Tasca

Fes una anàlisi arquitectònica completa i proposa un pla detallat de migració.

## 1. Anàlisi de la situació actual

Analitza:

* arquitectura actual
* punts d'entrada del renderitzat
* dependències entre backend i frontend
* limitacions de les funcions actuals
* impacte de substituir els renderitzadors actuals

## 2. Compatibilitat tècnica

Analitza:

* LiquidJS dins Supabase Edge Functions (Deno)
* Docxtemplater dins Supabase Edge Functions (Deno)
* possibles limitacions
* dependències necessàries
* rendiment
* seguretat

## 3. Arquitectura objectiu

Proposa una arquitectura clara basada en:

### Template Context Builder

Servei responsable de construir el context final de dades.

Ha de ser reutilitzable per:

* emails
* html
* documents
* previsualitzacions

### Liquid Template Renderer

Responsable de:

* subject
* html
* text
* layouts

### Docx Template Renderer

Responsable de:

* renderitzat DOCX
* loops
* condicionals
* integració amb signatures

### Template Validation Service

Responsable de:

* validar sintaxi
* detectar errors abans de desar
* validar plantilles durant les previsualitzacions

### Template Migration Service

Responsable de:

* detectar plantilles antigues
* convertir sintaxi antiga
* mantenir compatibilitat durant la migració

## 4. Model de dades

Analitza si:

* variables_schema
* signing_roles_schema

són suficients per convertir-se en la font única de veritat del sistema.

Proposa un model de context unificat que pugui alimentar:

* LiquidJS
* Docxtemplater
* previsualitzacions
* autocompletat
* documentació de variables

Exemple:

```ts
{
  worker: {
    id: "...",
    full_name: "John Doe",
    email: "john@example.com"
  },
  company: {
    name: "ACME"
  }
}
```

Volem que el nou sistema de plantilles permeti fer cose com per exemple treure taules de llistats d'empletas o coses similars.

Explica quina estructura recomanes i per què.

## 5. Frontend

Proposa els canvis necessaris a:

### Editor de correus

* validació LiquidJS
* previsualització LiquidJS real
* ajuda contextual
* autocompletat de variables

### Editor de documents

* validació Docxtemplater
* detecció d'errors
* autocompletat
* suport de blocs condicionals i loops

### Previsualitzacions

Volem que la vista prèvia utilitzi exactament el mateix motor que la generació real per evitar discrepàncies.


Analitza com implementar-ho.

## 6. Migració

Proposa un pla per fases.

Per cada fase indica:

* objectiu
* canvis
* riscos
* estratègia de rollback

Analitza especialment:

### Conversió automàtica

De:

```html
{{#if variable}}
...
{{/if}}
```

a:

```liquid
{% if variable %}
...
{% endif %}
```

I de:

```html
{{#unless variable}}
...
{{/unless}}
```

a:

```liquid
{% unless variable %}
...
{% endunless %}
```

### Compatibilitat temporal

Explica si convé:

* migració total
* migració progressiva
* suport dual durant un temps

## 7. Integració amb signatures

Analitza l'impacte sobre:

* signing_roles_schema
* etiquetes DocuSeal
* camps de signatura
* generació de documents per múltiples signants

Proposa la millor arquitectura perquè les signatures continuïn funcionant sense regressions.



## 8. Resultat final

Retorna:

1. Arquitectura objectiu.
2. Decisions tècniques recomanades.
3. Flux complet de renderitzat.
4. Model de context recomanat.
5. Pla de migració per fases.
6. Tasques backend.
7. Tasques frontend.
8. Tasques base de dades.
9. Riscos i mitigacions.
10. Exemples de codi quan siguin necessaris.

No implementis res encara.

Primer fes una revisió arquitectònica exhaustiva i justifica totes les decisions.