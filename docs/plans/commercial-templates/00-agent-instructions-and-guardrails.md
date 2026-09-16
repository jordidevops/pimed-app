# 00 — Instruccions per a agents IA i guardrails

> **Lectura obligatòria abans d'obrir cap fitxer d'aquest pla per implementar-lo.**
> Aquest document té prioritat sobre qualsevol impuls de l'agent d'"acabar-ho tot". Si alguna instrucció d'aquí xoca amb l'ambició d'anar més ràpid, **guanya aquest document**.

## 1. Regla d'or: una fase per sessió

**Prohibit explícitament** intentar implementar més d'un epic (QT-0…QT-7, veure [`06-phases-and-backlog.md`](./06-phases-and-backlog.md)) en una sola conversa/sessió d'agent, encara que el context ho permeti tècnicament.

Per què: aquest pla toca RLS, resolució multi-tenant i el motor de renderitzat de documents legals (pressupostos). Un error compost en dos epics fets de cop és molt més difícil de localitzar que un error en un epic aïllat i provat.

Protocol obligatori a **cada** sessió:

1. Llegir [`STATUS.md`](./STATUS.md) i [`EXECUTION.md`](./EXECUTION.md) sencers abans de tocar codi.
2. Identificar **una única** fase activa (o un ítem de backlog acordat explícitament amb l'usuari).
3. Implementar-la, provar-la amb les seves proves d'acceptació ([`06-phases-and-backlog.md`](./06-phases-and-backlog.md)), i **només llavors**:
   - Actualitzar `STATUS.md` (estat real, no optimista).
   - Actualitzar `EXECUTION.md` (fase activa següent).
   - Aturar la sessió. No continuar "ja que hi som" amb l'epic següent.
4. Si un epic queda a mitges (bloquejat, ambigu, requereix decisió humana): marcar-lo ⚠️ amb una nota concreta del que falta, **mai** ✅.

Si l'usuari demana explícitament "fes tot el pla" en una sola sessió, l'agent ha de **respondre amb el risc** (canvis sobre seguretat multi-tenant i documents legals sense punts de verificació intermedis) i proposar dividir-ho igualment, no assumir silenciosament l'abast complet.

## 2. Selecció de model per tasca

| Tasca | Nivell de model recomanat | Motiu |
|-------|---------------------------|-------|
| QT-0 Contracte de context + validació legal (disseny SQL) | Raonament alt | Defineix el contracte que la resta d'epics no pot reobrir sense trencar coses |
| QT-1 Migracions SQL (resolver, columna, RLS) | Raonament alt + **revisió humana obligatòria abans de mergejar** | Toca aïllament multi-tenant; un error aquí és un incident de seguretat, no un bug visual |
| QT-2 Edge function / motor de renderitzat | Raonament alt | Ha de llegir `liquid-renderer.ts`/`docx-renderer.ts`/`context-builder.ts` reals abans d'escriure cap línia; no es pot improvisar sintaxi |
| QT-3 Redacció de clàusules i contingut de plantilles | Model estàndard | Contingut, no lògica; **però tot text legal requereix revisió humana explícita abans d'activar-se** — l'agent mai el dona per definitiu sol |
| QT-4 Frontend / i18n | Model estàndard | Treball repetitiu de UI seguint patrons ja existents (`/documents/templates`) |
| QT-5 Tests SQL/E2E | Raonament alt | Les proves d'aïllament i de fallback són les que realment demostren que no s'ha trencat res |
| QT-6/QT-7 DOCX (fase 2) | Raonament alt | Manipulació binària (Docxtemplater/PizZip) i pipeline de conversió; errors silenciosos són fàcils |

Si el sistema de l'agent no permet triar model explícitament, com a mínim **demanar el nivell de raonament més alt disponible** per a QT-1, QT-2, QT-5, QT-6 i QT-7.

## 3. Guardrails anti-al·lucinació i anti-destrucció

1. **Prohibit modificar el comportament de `buildCommercialDocumentHtml`** per als tenants sense plantilla pròpia. Qualsevol canvi en aquest camí s'ha de demostrar amb un test abans/després que produeixi sortida idèntica.
2. **Prohibit `DROP`/`ALTER` destructiu** sobre taules o columnes existents. Només `ADD COLUMN IF NOT EXISTS`, noves taules o funcions noves/`CREATE OR REPLACE`.
3. **Prohibit inventar-se signatures d'RPC, noms de columnes o sintaxi de LiquidJS/Docxtemplater.** Abans d'escriure una crida o una plantilla, **llegir el fitxer font real** (`grep_search`/`read_file`) per confirmar que existeix tal com es descriu aquí. Aquest pla és fidel a l'estat del codi el 2026-09-16; el codi pot haver canviat.
4. **Prohibit tocar fitxers fora de l'abast de la fase activa.** Cap refactor "ja que hi era" a `commercial-flow`, `signing` o altres mòduls.
5. **Obligatori regenerar `database.types.ts`** (i copiar-lo a `supabase/functions/_shared/database.types.ts`) després de qualsevol migració, seguint la comanda oficial del `copilot-instructions.md` de l'arrel del repositori.
6. **Obligatori seguir el protocol d'auditoria** (`data.audit_logs`, `data.log_audit_event()`) per a qualsevol acció de cicle de vida nova: activar/desactivar una plantilla `quote`/`delivery_note`, reconèixer un buit legal (`p_acknowledge_legal_gaps`).
7. **Si hi ha ambigüitat tècnica no resolta en aquest pla** (per exemple: si Docxtemplater resol `[[tenant.name]]` amb notació de punt o cal aplanar les claus — veure nota a `01-context-and-legal-content.md`), l'agent **s'ha d'aturar i verificar-ho amb una prova mínima o preguntar**, mai assumir-ho i continuar.
8. **Cap epic es marca ✅ a `STATUS.md`** sense haver executat les proves d'acceptació corresponents i haver-les vist en verd. "Hauria de funcionar" no és una verificació.
9. **Tot text legal/clàusules** (doc 01) porta l'avís ja establert al pla comercial: no és assessorament jurídic. L'agent no pot presentar-lo com a validat legalment; només com a contingut per revisar.
10. Si una decisió marcada com "tancada" (README § Decisions tancades) s'ha de reobrir, **documentar-ho explícitament abans de tocar codi**, igual que exigeix el pla `commercial-flow`.

## 4. Senyals d'alarma (parar i preguntar a l'usuari)

- El resolver de plantilla completa retorna una plantilla d'un altre tenant, encara que sigui en un test.
- Cal tocar `commercial_document_events`, `commercial_documents` o qualsevol trigger d'immutabilitat existent més enllà d'afegir la columna `full_body_template_id`.
- El test de fallback (tenant sense plantilla pròpia) produeix una sortida diferent de l'actual.
- La validació legal (`validate_commercial_template_locale`) sembla necessitar lògica molt més complexa que una cerca de tokens — és senyal que l'abast s'ha de renegociar amb l'usuari, no ampliar-lo unilateralment.
