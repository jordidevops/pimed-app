# Decisions CF-22 (O-D*)

> No reobrir sense entrada al registre del [`README.md`](./README.md).  
> Hereten CT-D* del [pla CT](../pla-pressupost-contracte-acords.md). Especialment **CT-D8**: el PDF d’acord no muta `authorized_total`.

| ID | Decisió |
|----|---------|
| **O-D1** | Obra formal = `commercial_agreements.kind = 'project'`. Cap taula `obra`. |
| **O-D2** | Obra **simple** pot usar `signed_quote` o acord `specific` **sense** fites. CF-22 és opcional. |
| **O-D3** | Autoritat econòmica = quotes + ampliacions acceptades (`authorized_total` per projecte). Les fites **distribueixen** import/calendari; la suma de fites **no** redefineix el contractat. |
| **O-D4** | Ordre de canvi = CF-9 (`quote_amendment` acceptat). No hi ha entitat «CO» ni `agreement_id` a `commercial_documents`. |
| **O-D5** | Bestreta = `record_payment` sobre quote/amendment (avanços FIFO ja existents). CF-22 **exposa** saldos; no inventa `payment_kind` ni taula de bestreta. |
| **O-D6** | **Facturat** (seguiment) = suma d’imports de factures natives `issued` enllaçades als DN dels projectes de l’acord (CF-27) **més** refs externes encara vives si n’hi ha. **No** Verifactu/SII. Cancel·lades no compten. |
| **O-D7** | **Executat** (seguiment) = suma de `total` dels albarans `doc_type=delivery_note` amb `status=issued` dels projectes enllaçats. **No** costos CF-20, **no** actuals de línia, **no** drafts. Mateixa base monetària que el DN vs `authorized_total`. |
| **O-D8** | Variants d’oferta, retencions de garantia, IPC: **fora** de CF-22 (tot i el text genèric a `04-phases-and-backlog.md`). |
| **O-D9** | Una fase CF-22 per sessió d’implementació. |
| **O-D10** | Un acord `project` pot tenir N projectes (N:M existent). El seguiment V1 es calcula **per `project_id`**. Rollup a l’acord = suma dels projectes enllaçats. UI principal a la fitxa OS; resum a l’acord. |
| **O-D11** | Fita: font de veritat = `amount_cents` (≥ 0). El `%` és **derivat** per UI (`amount / contracted * 100`). Validació: suma d’`amount_cents` de fites actives de la versió ≤ `authorized_total` del projecte principal de la versió **o**, si hi ha N projectes, ≤ suma d’`authorized_total` dels enllaçats al preparar (documentar a RPC). No exigir suma = 100%. |
| **O-D12** | Completar / marcar una fita **no** crea factura, període de billing, ni DN. Facturació = hub Comercial. |
| **O-D13** | Fites viuen a **`commercial_agreement_versions`** (`version_id` FK). Editables només si la versió està en estat editable (draft / equivalent pre-`pending_signature`). Un cop `pending_signature` o `signed`, immutables (mateix esperit que `trg_commercial_agreement_versions_immutable`). Nova versió d’acord = nou joc de fites (còpia opcional des de l’anterior). |
| **O-D14** | Permisos escriptura prepare / fites / marcar fita = **owner o manager** del tenant (igual que `prepare_agreement_from_quote`). Lectura = membres amb accés a l’acord/OS. **No** `invoices.manage`. |
| **O-D15** | Estat fita V1: `planned` \| `completed` \| `cancelled`. Transició a `completed` = acció manual d’oficina. Sense evidència DN obligatòria. |
| **O-D16** | Plantilla seed «Acord d’obra»: text **no revisat per advocat** (com altres seeds). Banner/copy de producte honest; revisió legal = fora (pla CT §11.4). |
| **O-D17** | Desbloquejar `kind=project` al trigger **i** a `prepare_agreement_from_quote` (`p_kind`). Sense GUC de tests en producció; el camí normal és UPDATE del trigger com es va fer amb `framework`. |
| **O-D18** | Reetiquetar UI: `specific` ≠ «Obra» de CF-22. Proposta: specific = «Encàrrec / instal·lació puntual»; project = «Obra amb fites». |

## Definicions de seguiment (resum)

```text
contractat(project)  = projects.authorized_total
executat(project)    = Σ DN.issued.total  (project_id)
facturat(project)    = Σ invoices.issued vinculades via DN links (o refs externes actives)
avancat(project)     = pool avanços FIFO ja calculat (reutilitzar, no recalcular a cegues)
pendent_executar     = max(0, contractat - executat)
pendent_facturar     = max(0, executat - facturat)   -- aproximació; DN sense factura
```

Si `executat > contractat` (desviació / bug / ampliació pendent), mostrar el número real; no clamp silenciós a la UI de seguiment (el gate DN ja existeix a emissió).
