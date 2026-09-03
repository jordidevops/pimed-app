# Auditoria: `plantilles-documentals.md` vs codi (juny 2026)

Informe breu de contrast entre el document d'ajuda, els plans funcionals i l'estat real del repositori.

---

## Resum executiu

El document cobreix bé els **esquemes JSON**, els **dos enfocaments de variables** (schema-based vs path-based) i la **sintaxi DOCX/HTML bàsica**. Falten o estan desactualitzades: **blocs de contingut**, **wizard IA**, **LiquidJS**, **convenció de claus de rol** (`worker` vs etiquetes en català), **`catalog_item`**, limitacions de **signatura nativa DOCX**, i **auditoria `DOCUMENT_GENERATED`**.

---

## Taula per funcionalitat

| Funcionalitat | Estat | Notes |
|---------------|--------|-------|
| **1.1 Blocs de contingut (headers/footers)** | Implementada, **no documentada** | DB + UI settings + `BlockMappingSection` + render HTML a `sign-document-router` i preview. `PAGE_HEADER`/`PAGE_FOOTER` via Gotenberg només HTML. DOCX: slots a UI però servidor **no aplica** PAGE_HEADER/FOOTER. `CUSTOM` a DB/servidor sense slot a UI. |
| **1.2 Wizard IA** | Implementada, **no documentada** | `TemplateAiWizard`, validació Zod/Liquid, preview, diff sobreescriptura, generació nativa (`/settings/ai`), botó a fitxa d'idioma. |
| **1.3 LiquidJS (filtres, condicionals)** | Implementada parcialment, **no documentada** | LiquidJS 10 estàndard (`date`, `upcase`, `if`/`for`). S'aplica al cos HTML i als blocs injectats al context. Sense filtres personalitzats del projecte. |
| **1.4 Camps signatura DOCX** | Documentada, **parcialment precisa** | Sintaxi `{{Camp;role=Rol;type=TIPUS}}` correcta. DocuSeal: tots els tipus. **Signatura nativa**: només `type=signature` es substitueix; altres tipus queden per DocuSeal. |
| **1.5 Entity types / camps** | Documentada, **desactualitzada** | Falta `catalog_item`. Camps extra: `employee.starts_on`, `employee.status`, camps `tenant.*` ampliats. `user`/`person` al schema UI però **no resolts server-side** a `context-builder`. |
| **1.6 `DOCUMENT_GENERATED` audit** | **No implementada** | Només `TEMPLATE_*`, `TEMPLATE_LOCALE_*`, `SIGNING_SUBMISSION_*`, `ROLE_DEFAULT_*`. Generar document pot crear submission però sense event dedicat. |
| **Rols: clau tècnica vs label** | Document amb **exemples incorrectes** | El codi i seeds usen claus anglès (`worker`, `hr_manager`). El doc usa `Treballador` com a clau a molts exemples. |
| **Plantilles seed (15×2)** | Existents, **millorables** | HTML + DOCX, archetypes parcials. Dates sense filtre `date:` a la majoria d'HTML. |
| **Wizard: configuració prompt** | **Parcial** | Només «Tipus de document»; falten opcions de signants, rols, entitats (Part 5 sol·licitada). |

---

## Canvis previstos al document d'ajuda

1. Nova secció **Blocs de contingut** (tipus, mapping, duplicació).
2. Nova secció **Generació amb IA** (flux wizard, JSON per locale, copiar des de…, `/settings/ai`).
3. Nova secció **Sintaxi LiquidJS** (filtres, dates `dd/mm/aaaa`, condicionals).
4. Actualitzar taules `entity_type` i camps; afegir `catalog_item`.
5. Corregir exemples: claus de rol en `snake_case` anglès (`worker`), labels en català.
6. Nota signatura nativa vs DocuSeal per tipus de camp DOCX.
7. Nota: automatitzacions — encara no hi ha `DOCUMENT_GENERATED`; usar submissions com a proxy.

---

## Canvis previstos a plantilles (seed)

1. Afegir `| date: "%d/%m/%Y"` a variables `type: date` en HTML existent (migració UPDATE).
2. Afegir plantilles noves per arquetips (migració INSERT) — veure `20260617000001_seed_extra_document_templates.sql`.
3. Assignar `default_block_mapping` on convingui (peu legal RGPD).

---

## Decisions d'interpretació

| Decisió | Motiu |
|---------|--------|
| Noves plantilles majoritàriament **HTML** | Editor, preview, wizard IA; DOCX només quan cal format Word ric (no escala en aquesta iteració). |
| NDA / vacances / RGPD **no duplicades** | Ja existeixen com a plantilles 005, 002, 013. |
| Carta advertència, teletreball, etc. **noves** | Cobertura de la llista Part 4. |
| DOCX seed existent **sense canvis** en aquesta passada | Millores HTML prioritàries; DOCX es manté via `scripts/generate-docx-seed.mjs`. |
