# Prompt per a la IA implementadora

Tens accés complet al codi del repositori. Adjunt trobaràs el fitxer `header_footer_doc_templates_v2.md` amb el pla funcional/tècnic acordat per al sistema de Headers, Footers i Blocs de Contingut en plantilles de documents (HTML i DOCX).

## Objectiu

Revisar el pla, contrastar-lo amb el codi real existent, i produir un **pla detallat d'implementació** (tasques concretes, fitxers afectats, migracions, etc.), seguint les instruccions de la secció 7 del document. Un cop validat el pla detallat, procedir a la implementació.

## Requisits funcionals addicionals (a incorporar al pla detallat)

El sistema ha de quedar **"tancat"**, és a dir, utilitzable de cap a cap sense passos manuals previs. Concretament:

### 1. Blocs proporcionats per la plataforma ("blocs de sistema")
- Seguir el mateix patró que ja existeix a `/documents/templates`, on hi ha **Plantilles pròpies** vs **Plantilles del sistema**. Aplicar l'equivalent a `document_content_blocks`:
  - Revisar com es distingeix actualment "sistema" vs "tenant/site" a `document_templates` (camp `tenant_id` null? flag `is_system`? taula separada?) i replicar exactament el mateix mecanisme per als blocs, per coherència.
- La IA ha de **crear un seed de blocs de sistema** (HTML i TEXT) llestos per usar, organitzats per `block_type` i casos d'ús habituals:
  - `PAGE_FOOTER` (TEXT): peu legal estàndard amb `[[ tenant.name ]]` / `{{ tenant.name }}`, número de pàgina, avís de confidencialitat.
  - `PAGE_HEADER` (HTML): capçalera amb logo del tenant + nom, capçalera per documentació ISO (codi document, versió, data), capçalera RRHH (logo + "Document intern de Recursos Humans").
  - `DOCUMENT_HEADER`/`DOCUMENT_FOOTER` (HTML): bloc de portada simple, bloc de signatura/peu de correu corporatiu, avís legal extens per a contractes.
  - `CUSTOM`: bloc de clàusula de protecció de dades (RGPD), bloc de control de versions per documentació ISO (taula amb versió/data/autor).
  - Cobrir com a mínim: documentació general d'empresa, RRHH, documentació ISO/qualitat. Redactar els continguts en català (o el locale per defecte del projecte — revisar i mantenir consistència amb altres seeds existents).
  - Implementar com a migració/seed SQL (o script, seguint el patró d'altres seeds del projecte) per a `document_content_blocks` amb `tenant_id`/equivalent de sistema.

### 2. Clonació de blocs de sistema (tenant/site)
- A "Blocs de Contingut" (`/settings/documents` o equivalent), el tenant/site ha de poder:
  - Veure els blocs de sistema (només lectura) separats dels propis, amb la mateixa UX que ja existeix per a plantilles del sistema vs. pròpies.
  - **Clonar** un bloc de sistema: crea una còpia editable amb `tenant_id`/`site_id` del propi tenant/site, mateix `block_type`/`format`/`content` inicial, i un nom per defecte tipus "Còpia de [nom original]" (revisar si ja hi ha aquest patró de clonació per a plantilles i reaprofitar-lo).
  - Crear blocs propis des de zero (ja contemplat al pla original, Fase 2).

### 3. Selecció de blocs en generar/configurar documents
- A la UI de configuració de la plantilla (Fase 3 del pla), el selector de cada tipus de bloc (`page_header`, `page_footer`, `document_header`, `document_footer`, `custom_*`) ha de llistar **tant els blocs de sistema com els del tenant/site**, deixant clar visualment quins són de sistema (igual que a la llista de plantilles).
- No cal "clonar abans de seleccionar": el tenant pot assignar directament un bloc de sistema sense clonar-lo. La clonació (punt 2) és només per a quan vulguin **editar-lo**.

### 4. Persistència de la selecció (`default_block_mapping`)
- Confirmar/implementar que en seleccionar un bloc per a qualsevol dels tipus disponibles, el `uuid` queda desat a `default_block_mapping` de `document_templates` (Fase 1/3 del pla original).
- En usos posteriors de la plantilla (tant a la UI d'edició com en la generació real del document), el mapeig desat s'ha de carregar automàticament sense requerir selecció manual.
- Si un bloc seleccionat (de sistema o propi) s'esborra o deixa d'estar disponible, definir comportament (fallback: ignorar el bloc / avisar a la UI / impedir esborrar blocs en ús — revisar com es gestiona aquest cas per a plantilles i aplicar el mateix criteri).

### 5. Àmbit tenant vs. site
- El pla original deixa obert si els blocs són per `tenant`, per `site`, o ambdós (punt 7.7). Cal **revisar com es resol aquesta jerarquia per a `document_templates` i `document_content_blocks` actuals** (si ja existeixen) i aplicar el mateix model de precedència (ex: bloc de site sobreescriu bloc de tenant, que sobreescriu bloc de sistema) tant per a la llista de blocs disponibles com per a `default_block_mapping`.

## Entregables esperats

1. Pla detallat d'implementació (fitxers, migracions, components UI, seeds).
2. Implementació del codi corresponent.
3. Seed de blocs de sistema (contingut real, no placeholders).
4. Breu resum final de canvis i de qualsevol decisió presa on el pla original deixava marge d'interpretació.