# Import CSV d'empleats

> EX-08.4 / EI1 / **EHR-7** — import inbound de persona/directori (gestoria, Excel, export Holded…).  
> **Connectors natius Holded / PayFit / sync programat (EI3–EI6):** backlog — no formen part d'aquesta UI.

## Com fer-ho

1. A **Empleats**, clica **Importar CSV** (owner/manager).
2. Descarrega la plantilla i adapta les columnes del teu Excel.
3. Puja el fitxer (separador `;` o `,`).
4. Revisa la previsualització per dominis: **empleat** · **perfil privat** · **contracte** (EC diferit).
5. Confirma.

## Columnes acceptades

| Canònic | Àlies |
|---------|--------|
| `full_name` (obligatori) | `nombre`, `name`, `nom` |
| `employee_code` | `codi`, `codigo`, `code` |
| `document_id` | `nif`, `dni`, `nie` |
| `email` | `correo`, `mail` |
| `phone` | `telefono`, `telefon` |
| `legal_name` | `nom_legal` |
| `preferred_name` | `nom_preferit` |
| `job_position_ref` | `posicio`, `position`, `cargo`, `càrrec`, `carrec`, `job_title` (codi o nom del catàleg «Lloc de treball»; `cargo`/`càrrec`/`job_title` són àlies de `job_position_ref`) |
| `manager_external_ref` | `manager`, `responsable` (codi / NIF / UUID / external_id) |
| `tags` | `etiquetes` (separades per `,` `\|` o `;`) |
| `status` | `estat`, `estado` (`active` / `inactive` / `terminated`) |
| `starts_on` | `fecha_alta` (ISO date) — legacy a fitxa; conflicte amb contracte firmat → revisió |
| `ends_on` | `fecha_baja` |
| `weekly_hours` | `horas_semanales` — igual; no sobrescriu si el contracte EC està firmat |
| `external_id` | `id_extern` |
| `provider` | (opcional; per defecte `csv`) |
| `personal_email`, `personal_phone`, `birth_date`, `address`, `postal_code`, `city`, `social_security_number`, `iban`, `emergency_contact_*` | Perfil privat — **només** si el JWT té `employees.private.manage` explícit. IBAN/NSS es xifren en desar. |

No s'importen (s'ignoren amb avís): `contract_type`, `conveni`, `category`, `salary` ni equivalents a `metadata`. L'import de contractes és EC; certificacions, CR.

## Match (idempotent)

1. Mapping `(provider, external_id)` → actualitza.
2. `employee_code` → actualitza.
3. NIF normalitzat.
4. Email (si NIF divergeix → `EMAIL_NIF_MISMATCH`).
5. Sinó → crea (+ mapping si hi ha `external_id`).

## Dominis a la previsualització

| Domini | Comportament |
|--------|----------------|
| Empleat | Sempre (create/update) |
| Privat | `applied` / `no_permission` / `none` |
| Contracte | `deferred_ec` (per defecte) · `needs_review` si xoca amb contracte firmat · `no_conflict` |

## Backlog (no en aquest flux)

- EI3 framework connectors (`tenant_hr_connectors`)
- EI4 Holded inbound
- EI5 PayFit inbound
- EI6 resync programat
- Import bulk de contractes (EC) i certificacions (CR)
