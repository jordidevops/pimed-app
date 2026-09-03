DONE
> **Rol:** Senior SaaS Architect & Fullstack Developer.
>
> **Context:** Tenim un sistema d'emails en PostgreSQL/Next.js. Volem consolidar la interfície d'usuari i la lògica de resolució sota el model "Fallback Jeràrquic amb Copy-on-Write".
>
> **L'Arquitectura de Dades (Ja existent parcialment):**
> * `data.email_templates`: Taula única que allotja tant plantilles de plataforma (`is_platform_default = true`, `tenant_id = null`) com de tenant (`is_platform_default = false`, `tenant_id = UUID`).
> * **Layouts (Wrappers):** Marcats amb `is_layout = true`.
> * **Contingut (PC):** Marcats amb `is_layout = false`.
>
> **Especificacions d'Implementació:**
>
> **1. Lògica de Renderitzat i Placeholders (Edge Function / RPC):**
> * La variable reservada per injectar contingut dins d'un layout és estretament `{{content}}`.
> * *Regla HTML:* El HTML final és = Layout HTML (substituint `{{content}}` pel PC HTML).
> * *Regla TXT:* Els layouts no apliquen al text pla. El TXT final és exclusivament el `text_body_template` de la PC.
> * Assegura't que `api.enqueue_email` i el Worker apliquen aquesta jerarquia de fallback exacte:
>     1. Buscar PC per `tenant_id` + `event_type`. Si no hi és -> Buscar PC on `is_platform_default = true`.
>     2. Buscar Layout definit a la PC. Si no n'hi ha -> Buscar `default_layout_id` a `email_configs`. Si és null -> Sense layout.
>
> **2. Tenant-Portal (UI - "Plantilles d'Email"):**
> * **Llistat Combinat:** Mostra una llista d'events disponibles (ex: "Registre", "Reset Password").
> * Per a cada event, el frontend ha de comprovar si el tenant té una plantilla pròpia o si està usant la de plataforma.
> * **Estat Visual:** Mostra un badge: "Personalitzada" (si és del tenant) o "Per defecte de la plataforma" (si ve del fallback).
> * **Acció "Copy-on-Write":** Si l'usuari clica "Editar" en una plantilla de plataforma, el frontend NO edita la global. Fa un `INSERT` d'una nova plantilla clonant les dades de la plataforma, però assignant el seu `tenant_id` i `is_platform_default = false`.
> * **Acció "Restaurar valors per defecte":** Un botó per eliminar (`DELETE`) la plantilla del tenant, fent que el sistema torni a caure automàticament en el fallback de la plataforma.
>
> **3. Editor de Plantilles (UI):**
> * Obliga a l'usuari a previsualitzar com quedarà la seva plantilla PC embolicada dins del seu Layout (PBT) actual.
> * Implementa un mode `draft` / `published` si és possible a nivell d'UI (amb un flag boolean simple a la BD), o bé versionat per clonació visual ("Duplicar plantilla").