# Glossari Legal & Compliance

Sigles i termes del pla [`README.md`](./README.md).

## Normativa

| Sigla | Significat |
|---|---|
| **RGPD** | Reglament General de Protecció de Dades (UE). Anglès: **GDPR**. |
| **GDPR** | General Data Protection Regulation (= RGPD). |
| **ePrivacy** | Norma UE sobre privacitat electrònica (cookies, comunicacions). |
| **LSSI** | Llei de Serveis de la Societat de la Informació (ES) — avís legal web. |
| **LOPDGDD** | Llei orgànica espanyola que adapta el RGPD. |
| **Art. 13** | Deure d’informar l’interessat quan es recullen dades. |
| **Art. 6.1.b** | Base jurídica: execució de contracte. |
| **Art. 14** | Informar quan les dades no venen de l’interessat. |

## Rols i documents

| Sigla | Significat |
|---|---|
| **DPA** | Data Processing Agreement — acord responsable ↔ encarregat. |
| **DPO** | Data Protection Officer — delegat de protecció de dades. |
| **CMP** | Consent Management Platform — mur/banner de cookies amb categories. |
| **DSAR** | Data Subject Access Request — petició de drets de l’interessat. |
| **PII** | Personally Identifiable Information — dades personals identificatives. |
| **NIF** | Número d’Identificació Fiscal. |

## Producte

| Sigla | Significat |
|---|---|
| **CP** | Customer portal (`apps/customer-portal`). |
| **PP** | Public portal (web pública). |
| **EP** | Employee portal (`/portal`). |
| **LC-n** | Fases d’aquest pla (Legal Compliance). |
| **REC-0** | Paquet legal inicial del mòdul recruitment. |
| **CRM** | Contactes / comptes client. |
| **CMS** | Editor de pàgines de la web pública. |
| **ATS** | Applicant Tracking System (selecció). |
| **RRHH** | Recursos humans. |
| **IA** | Intel·ligència artificial (features amb checklist DPA). |

## Tècnica

| Sigla | Significat |
|---|---|
| **UI / API / RPC** | Interfície / endpoints / funcions Postgres via Supabase. |
| **TTL** | Temps de vida (sessió, dismiss, link). |
| **CDN / ETag** | Caché i revalidació de `/legal`. |
| **HttpOnly** | Cookie no llegible per JavaScript. |
| **UE** | Unió Europea. |

## Termes (no sigles)

- **Tenant** — empresa client SaaS; responsable del tractament.
- **Encarregat / processor** — la plataforma.
- **Soft-duty** — avís de deure sense bloqueig dur.
- **Hard-block** — impedeix l’acció fins a complir.
- **Read-through** — careers llegeix Legal Center sense migrar settings encara.
- **Purge** — esborrat programat per retenció.
- **Allowlist** — camps permesos a la projecció pública.
