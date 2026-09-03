# Base jurídica, DPA i informació al destinatari (Art. 13)


> **Contracte CP-0.6** — 2026-08-04.  
> Pla portal: [`README.md`](./README.md) · Projecció/retenció: [`projection-and-retention.md`](./projection-and-retention.md).  
> **Mòdul Legal unificat (plataforma):** [`../legal-compliance/README.md`](../legal-compliance/README.md) · execució [`../legal-compliance/EXECUTION.md`](../legal-compliance/EXECUTION.md).  
> Versió: **1.0** — text orientatiu de producte; el text legal vinculant el valida assessoria.

Aquest document defineix **qui fa què** i què ha de veure el destinatari en el context del **butlletí / customer-portal**. El catàleg de plantilles, cookie notice, avís LSSI i Legal Center de tenant viuen al pla **legal-compliance**. No substitueix el DPA signat ni la política de privacitat del tenant.

DPA = Data Processing Agreement (Acord de Tractament de Dades)

---

## 1. Rols

| Rol | Qui | Responsabilitat típica |
|---|---|---|
| Responsable del tractament | El **tenant** (empresa que presta el servei al client final) | Decideix destinataris, finalitat, termini; compleix Art. 13/14 envers el seu client |
| Encarregat del tractament | La **plataforma** (operador SaaS) | Tracta dades sota instruccions del tenant (DPA); seguretat tècnica, logs, retenció operativa |
| Destinatari / interessat | Persona que rep el link o accedeix al portal | Rep informació clara sobre el tractament quan accedeix |

El tenant és responsable de triar persones destinatàries amb base legítima i de no usar canals no verificats quan el producte ho exigeix (invitacions persistents, TTL ampliat).

---

## 2. Base jurídica habitual

Per compartir un **part / butlletí d’intervenció** amb el client del servei:

- Base habitual: **execució del contracte** de prestació de servei (o mesures precontractuals si aplica).
- Altres bases (consentiment, interès legítim) només si el tenant les documenta; el producte no assumeix consentiment implícit només per tenir un email al CRM.

El tenant ha de poder justificar per què aquella persona concreta rep aquell artefacte (relació empresa-persona activa).

---

## 3. Abans d’enviar (UI tenant)

La UI de share/email ha de mostrar, com a mínim:

1. Empresa o persona contractant (`customer_account_contact_id`).
2. Persona destinatària i canal (email/phone).
3. Caducitat del link.
4. Resum de què es publica (camps/media de la projecció).

Confirmació explícita abans de crear la share o encuar l’email.

---

## 4. Informació Art. 13 al reader

La pàgina pública del butlletí (i el portal Fase B) ha d’enllaçar a informació de privacitat del **tenant** (Art. 13), perquè el destinatari pot no haver vist mai la política original.

Contingut mínim esperat (el tenant el subministra / URL):

- Identitat del responsable (tenant).
- Finalitat: lliurar el butlletí / accés al portal del servei.
- Base jurídica.
- Destinataris / encarregats (plataforma).
- Terminis de conservació (o criteris).
- Drets (accés, rectificació, oposició, supressió, reclamació a l’autoritat).
- Contacte del DPO o del responsable, si n’hi ha.

La plataforma pot oferir una pàgina plantilla; el tenant en respon el contingut. **Implementació unificada:** plantilles allotjades i Legal Center a [`../legal-compliance/README.md`](../legal-compliance/README.md) (mode plantilla / editat / URL externa).

---

## 5. Drets de l’interessat (operativa de producte)

| Dret / petició | Acció de producte |
|---|---|
| Baixa / oposició / supressió (persona) | Revocar shares, grants i sessions d’aquella persona; audit; aplicar retenció/bloqueig |
| Accés | El tenant exporta o mostra el que correspongui; logs d’accés ajuden |
| Rectificació de CRM | No reescriu versions publicades; nova versió corregida si cal |

La supressió del CRM **no** cascada-destruint evidència publicada.

---

## 6. Responsabilitat sobre destinataris

- El tenant tria i verifica destinataris.
- `contacts.email` / `phone` CRM ≠ canal verificat per invitació persistent.
- Errors d’enviament a tercers (email mal triat) són responsabilitat del tenant; la plataforma aporta confirmació UI, canals verificats i auditoria.
- Sessions staff («veure com el client») són accés de suport del responsable; queden auditades amb `staff_user_id` i no es fan passar per accés del client.

---

## 7. DPA plataforma ↔ tenant

El DPA ha de cobrir, com a mínim:

- Objecte: allotjar i servir butlletins/shares/portal sota instruccions del tenant.
- Mesures tècniques: hash de secrets, rate limit, kill-switch, minimització, logs.
- Subencargats (hosting, email provider) i transferències.
- Assistència en drets dels interessats i incidents.
- Retorn/supressió al final del contracte, amb excepcions d’obligació legal.

Text contractual definitiu: legal / ops; aquest fitxer només fixa requisits de producte.
