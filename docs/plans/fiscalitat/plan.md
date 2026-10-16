## Plan: Fiscalitat configurable i multi-moneda

Preparar PiMed per a tipus fiscals canviants i multi-moneda sense alterar documents emesos. El disseny manté separats (1) PiMed → tenants, on ara hi ha preus de plans però no un ledger de facturació complet, i (2) tenants → clients, on hi ha documents comercials interns amb snapshots però no compliment fiscal. La primera entrega ha de consolidar l’euro i fiscalitat configurable a Espanya; la internacionalització completa depèn de definir operador fiscal i decidir motor propi vs proveïdor (Stripe Tax/MoR o equivalent).

**Passos**
1. **Tancar política i límits.** Reobrir formalment CF-D8 (EUR únic) i S-D12 (Verifactu/compliment fiscal fora d’abast) només per definir l’arquitectura, sense prometre que els documents actuals ja són factures fiscals. Definir jurisdicció inicial, data fiscal de referència (devengo/tax point), productes/serveis coberts, qui és venedor/merchant of record a cada flux i quins països entren al primer llançament. Consultar assessor fiscal abans de producció internacional.
2. **Especificar primitives de diners i divises.** Formalitzar ISO-4217 (codi, decimals), imports decimals/cèntims i arrodoniment; diferenciar moneda del preu del catàleg, moneda de cobrament/presentació i moneda fiscal/reporting. Definir FX amb parell i convenció explícita, font oficial, instant/data d’efecte, valor, data de publicació, timestamp d’obtenció i regla de fallback. En context espanyol, preparar imports reportables en EUR segons normativa vigent, sense afirmar que tota factura hagi d’imprimir tots els imports en EUR. Mai fer càlcul monetari amb float binari.
3. **Dissenyar catàleg de regles fiscals versionat.** Regles per jurisdicció, tipus/categoria de subministrament i classificació de producte/servei, taxa, vigència `[valid_from, valid_until)`, font legal/oficial, data de consulta/publicació i estat de revisió. Històric append-only/versionat: un canvi legal crea una nova vigència, no reescriu documents ni regles aplicades. Definir manteniment controlat (importació/revisió/aprovació i alertes de vigències pròximes); no confiar en percentatges al codi ni scraping automàtic no verificat. Valorar base de dades oficial o proveïdor fiscal.
4. **Definir determinació d’impost i evidència.** Entrada amb identitat/jurisdicció fiscal del venedor, billing address del client (separada del site de servei), país i estat de Tax ID, B2B/B2C, categoria del subministrament, regla de lloc de prestació, data fiscal i règim/registres OSS quan pertoqui. VIES amb resultat, instant, sol·licitud/referència i fallades conservades; VIES no és una decisió fiscal completa. IP és només una evidència possible, no font única ni obligació universal. Retornar regla aplicada, taxa, base, quota, motiu d’exempció/reverse charge i text legal/localitzat.
5. **Modelar snapshots immutables i FX.** En emetre: congelar seller/buyer/billing address, línies, currency, tax category/jurisdiction, taxa i versió de regla, data fiscal, bases/quotes per tipus, totals, motius d’exempció, moneda i taxa FX/font/data, imports reportables, proveïdor/decisió fiscal i hash canònic de totes les entrades rellevants. Edició només mentre és draft; correccions post-emissió amb flux de rectificació/document nou, mai mutació de l’original. Separar invoice currency de settlement/reporting currency. Pagaments i allocations han de portar moneda; prohibir agregació silenciosa entre divises i deixar conversió/allocation cross-currency per una decisió explícita.
6. **Adaptar flux comercial tenant → client (depèn de 2–5).** Migració forward: completar currency de línies/projectes, imports i payments; ampliar contactes i perfils legals amb país/adreça fiscal/Tax IDs i registres; mantenir valors existents en EUR; actualitzar RPCs de draft/issue, càlcul SQL i el paquet `packages/price-calculator` perquè línies i previews tinguin el mateix resultat. Actualitzar servei, vistes API/RLS, UI, PDF/exportació/gestoria per mostrar el desglossament i avisos correctes. Preservar factures històriques; no reinterpretar tax_rate antic com a taxa actual. Fase inicial suggerida: Espanya i euro amb taxa configurable i snapshots; no activar OSS/UE internacional fins a completar determinació/evidència i aprovació fiscal.
7. **Preparar flux SaaS PiMed → tenant en via separada.** Versionar preus de plans/add-ons per moneda i vigència en lloc de convertir un únic `price_monthly`; associar currency i billing account al tenant; preparar subscripció amb snapshot de preu i període, invoices/payment events i FX/tax snapshot. Actualitzar admin MRR per separar i convertir només amb FX documentat, mostrant moneda nativa o total normalitzat amb data/font. No implementar un segon motor fiscal ni checkout real abans de decidir PSP/MoR i responsabilitat de facturació de PiMed.
8. **Rollout i operació.** Migracions forward idempotents, backfill EUR sense canviar valors, diagnòstic d’inconsistències abans d’escriure, auditoria d’edició/publicació de regles i events d’integració. Regenerar `database.types.ts` frontend i còpia Edge després de cada migració que afecti data/api/RPC; actualitzar Prisma si toca SaaS/admin. Feature flags i període de doble lectura; no doble-escriure documents emesos.

**Fitxers rellevants**
- `docs/plans/commercial-flow/README.md` — CF-D8 actual (només EUR) i context comercial.
- `docs/plans/commercial-flow/01-legal-requirements.md` — requisits existents, B2C/B2B actual i advertiment legal.
- `docs/plans/commercial-flow/02-domain-model.md` — `catalog_items`, `project_lines`, `commercial_documents`, línies, payments i càlcul.
- `docs/plans/commercial-flow/09-sales-comercial/README.md` — S-D12 exclou Verifactu/rectificatives fiscals i flux de factures internes.
- `docs/plans/commercial-flow/09-sales-comercial/01a-fase-invoice-core.md` — RPCs `issue_invoice`, `create_invoice_draft_from_delivery_notes`, `content_hash`.
- `docs/plans/commercial-flow/12-price-calculators/00-decisions.md` i `01-schema.md` — motor compartit portal/Deno i regles d’arrodoniment/preu/taxa actuals.
- `supabase/migrations/20260401000002_core_tables.sql` — `data.plans` i subscripcions actuals.
- `supabase/migrations/20260413000015_billing_summary_view.sql` — MRR aproximat actual.
- `supabase/migrations/20260503000006_catalog_and_project_lines.sql` — catàleg i línies operatives actuals.
- `supabase/migrations/20261160000001_commercial_flow_tall1_cf1_cf3_cf4.sql` — ledger de pagaments sense moneda.
- `supabase/migrations/20261159000041_legal_compliance_center.sql` — perfil legal del tenant actual.
- `supabase/migrations/20261217000001_sales_invoice_core.sql` — emissió/factures comercials i snapshots; confirmar el nom real/timestamp del repo en implementació.
- `apps/tenant-portal/src/features/commercial/api/commercialFlowService.ts`, `apps/tenant-portal/src/features/commercial/components/InvoicesPage.tsx`, `apps/tenant-portal/src/features/commercial/components/InvoiceDetailPage.tsx` — accés i UI comercial.
- `apps/tenant-portal/src/types/database.types.ts`, `supabase/functions/_shared/database.types.ts` — tipus generats duplicats obligatoris.
- `apps/admin-portal/prisma/schema.prisma`, `apps/admin-portal/app/dashboard/monetitzacio/page.tsx` — domini i vista d’ingressos SaaS.
- `packages/price-calculator` — càlcul decimal compartit i oracle de paritat.

**Verificació**
1. Tests SQL de vigències incloent canvi de taxa amb factura antiga immutable, intervals solapats rebutjats, taxa no trobada i categoria/país incorrectes.
2. Vectors daurats de moneda i FX: decimals ISO, taxa oficial datada, inversió de parell explícita, arrodoniments i imports originals/reportables; cap float binari.
3. Tests B2B: tax ID vàlid, invàlid, VIES unavailable i resultat auditable; reverse charge només quan la regla i el context determinen aplicabilitat.
4. Tests de lloc de subministrament: Espanya, UE B2C i B2B, serveis amb excepció; no assumir que tot B2C va per OSS ni tot B2B transfronterer és reverse charge.
5. Tests d’emissió: snapshot/hash inclou currency, tax breakdown, vigència, FX i buyer/seller; issued no editable; rectificació conserva original.
6. Tests de payments/allocations rebutgen barreja de moneda sense FX explícit; validació de visualització UI/PDF per invoice currency i tax/reporting amounts.
7. Tests SaaS de preus versionats/multi-currency i MRR separat per moneda; confirmar que estimació no suma imports de monedes diferents sense conversió traçable.
8. Reset local, suites SQL/Vitest/Deno afectades i validació de tipus generats. UAT amb tenant ES/EUR, comprador B2B UE, comprador B2C UE i pagament en moneda diferent.

**Decisions**
- Abast: tots dos fluxos, amb models, permisos, ledger i reporting independents.
- Objectiu: preparar arquitectura; decisió de proveïdor fiscal/PSP posterior.
- No canviar ni recalcular documents històrics; la vigència legal s’avalua en el moment fiscal de la transacció.
- Confirmat per recerca: els tipus són específics per estat membre i subministrament; OSS cobreix transaccions definides, no tota venda B2C; VIES valida números VAT però no substitueix la determinació fiscal.
- L’explicació inicial és orientativa però massa absoluta: el règim B2B/B2C té excepcions i dependències de tipus de servei/bé; billing address és central i IP pot ser evidència addicional conforme a règim concret; l’Article 91 regula conversió/reporting en moneda nacional i la factura pot expressar-se en moneda diferent subjecte a condicions. La data aplicable és el devengo/tax point segons norma, no necessàriament la data d’emissió. Validar els detalls d’Espanya/AEAT amb assessor fiscal abans de llançar.
- Fora d’abast d’aquest pla inicial: complir amb Verifactu o altres règims de factura electrònica, calcular tots els impostos mundials amb motor propi, i activar OSS/VIES automation o MoR sense decisió de producte i legal.

**Fonts oficials de referència**
- Comissió Europea, tipus d’IVA: https://taxation-customs.ec.europa.eu/taxation/vat/vat-directive/vat-rates_en
- Comissió Europea, OSS: https://vat-one-stop-shop.ec.europa.eu/index_en
- Comissió Europea, VIES: https://ec.europa.eu/taxation_customs/vies/
- Directiva 2006/112/CE, articles 44/58/91/226 (lloc de prestació, conversió i factures): https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:02006L0112-20240101