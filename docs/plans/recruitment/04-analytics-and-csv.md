# Analítiques i intercanvi CSV (REC-11, REC-12)

> **Pla pare:** [README.md](./README.md)

---

## Analítiques (REC-11)

### Ruta

`/recruitment/analytics`

### KPIs

- Candidatures / ofertes actives / hires / conversió
- Temps mitjà primera resposta / contractació
- Per `source` i `import_source_label`
- Descarta / entrevista / hire

### Gràfics

Funnel, evolució temporal, site/dept/oferta, fonts, temps per etapa.

### Regles RGPD (MVP, no diferit)

- Cap nom, email ni CV.
- Només agregats.
- **k-anonymity:** no mostrar (ni exportar) cap cel·la/cohort amb recompte **&lt; 5**; mostrar “—” o fusionar. Configurable `analytics_min_cohort` (default 5, mínim 3).
- Export informe agregat ≠ export operatiu PII.

### Implementació

- RPC `get_recruitment_analytics` amb suppressió de cohorts petites al servidor (no només UI).
- Permís `recruitment.view` per dashboard; export PII → `recruitment.manage` + audit.

---

## Intercanvi CSV (REC-12)

**Sense APIs** de job boards.

### Export

| Tipus | Permís |
|-------|--------|
| Candidatures (PII) | `recruitment.manage` |
| Ofertes (metadades) | `recruitment.view` |

**Forat dret a l’oblit (mitigació MVP):**

1. Diàleg d’advertència abans de descarregar: el fitxer surt del control de retenció PiMed; el tenant és responsable de destruir-lo quan calgui.
2. Descarrega via **URL signada TTL** (p.ex. 15 min), no attachment etern a email.
3. `audit_logs`: qui, quan, quants registres, filtre.
4. Opcional settings: `export_requires_rights_ack` checkbox obligatori.

El purge d’`applications` **no** pot esborrar CSVs ja descarregats; l’advertència + audit és el control de producte.

### Import

Patró [employee-import](../employee-import/plan.md):

1. CSV → oferta destí.
2. Mapatge + preview + validació email.
3. Dedupe email + `job_posting_id`.
4. Crea `applicant` + `application` (`source=csv_import`, CV a **application**).

### Base legal i Art. 14 (decisions tancades)

| Decisió | Detall |
|---------|--------|
| Base legal | **Configurable** a `recruitment_settings.import_legal_basis` (`legitimate_interest` \| `consent` \| `other` + text lliure). **No** hardcoded “interès legítim” al producte. |
| Art. 14 | Després d’import, si el candidat no té `email_verified_at` / no ve del portal: encuar `recruitment.art14_notice` (informació tractament, origen de les dades, drets, termini). Default: enviar en **≤ 30 dies** o a la primera comunicació, el que sigui abans. |
| Opt-out Art. 14 | Flag `art14_notice_sent_at` / `art14_suppressed` (si email invàlid bounce) |

### Publicació externa

Copiar URL / QR (`?src=qr`) / WhatsApp (`?src=whatsapp`).

---

## Fora d’abast

- Integracions API job boards, webhooks, XML feeds.

---

## Riscos

| Risc | Mitigació |
|------|-----------|
| Duplicats CSV + web | Dedupe; merge UI |
| Import sense informar interessat | Art. 14 automàtic + base legal configurable |
| CSV export fora de retenció | Advertència + TTL + audit |
| Re-identificació analytics | k-anonymity ≥5 al MVP (servidor) |
