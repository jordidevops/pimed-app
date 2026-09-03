# Public Portal - Locale Regression Matrix

## Scope
Validate that locale behavior is no longer tied to mandatory `ca` and that `default_locale` drives routing and content fallback.

## Automated checks executed

| Area | Case | Expected | Result |
|---|---|---|---|
| Build | public-portal production build | Compiles with TS OK | PASS |
| Runtime boot | next dev startup | Server starts (port conflict handled) | PASS |
| Runtime warning | I18nProvider language sync | No React setState-during-render warning | FIX APPLIED |
| Slug routing | `/acme-corp` and `/acme-corp/xx` | Redirect to default locale | PASS |
| Custom domain (canonical) | Host `foo.localhost` to `/es/contact` | `200 OK` | PASS |
| Custom domain (alternate) | Host `bar.localhost` to `/es/contact` | `308` to canonical | PASS |
| Lead API | POST `/api/leads` with valid payload | Lead created | PASS |
| Lead worker | `process-leads-queue` batch | 1 item succeeds | PASS |
| BCC enabled | `lead_ack_copy_email` configured | Confirmation email has BCC | PASS |
| BCC disabled | `lead_ack_copy_email` empty | Confirmation email has no BCC | PASS |
| No global owners | Owners scoped per site | Confirmation email still queued, no notifications | PASS |

## Manual checks status

| Area | Case | Expected | Result |
|---|---|---|---|
| Create portal (tenant UI) | Pick initial locale at creation | `supported_locales` + `default_locale` initialized with selection | PASS (`beta-startup`: created with `en` -> `supported_locales={en}`, `default_locale=en`) |
| Tenant config (tenant UI) | Uncheck `ca` and save | Save succeeds if at least one locale remains | PASS |
| Tenant config (tenant UI) | Uncheck all locales | UI blocks and shows validation | PASS |
| Tenant config (tenant UI) | Clear `contact_email_public` and `lead_ack_copy_email` | Values persisted as empty | PASS |
| Page editor (tenant UI) | Edit in non-base locale | Empty localized fields fallback to base locale content | PASS |
| i18n labels/placeholders (tenant UI) | SiteConfigForm + PageEditor placeholders and labels | Visible strings are localized | PASS |

## Notes
- Platform fallback locale in frontend runtime is `es` when no valid locale is available.
- Locale catalog remains constrained to `ca`, `es`, `en` in this phase.
- For fallback validation in editor, site locales were temporarily set to `es,en` and later restored to `ca,es`.
