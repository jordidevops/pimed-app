# BYOS SMTP — Documentació de disseny (pendent d'implementació)

## Contexte

El sistema d'email actual usa Resend com a únic transport. Resend limita a 10 dominis
personalitzats al pla de pagament estàndard, cosa que no escala a partir de ~10 tenants
amb domini propi. BYOS SMTP (Bring Your Own SMTP) permet que un tenant configuri el seu
propi servidor de correu (Google Workspace, Office 365, Postfix...) com a transport
alternatiu.

Decisions preses:
- **No implementar ara** — defer fins que hi hagi un client enterprise que ho demani.
- La cascada Resend custom domain → Resend platform cobreix el 95% dels casos actuals.
- Quan s'implementi, ha de ser un **addon de pla** (igual que `custom_domains`).

---

## Arquitectura prevista

### Cascada de transport (dins `process-email-queue`)

```
resolveTransport(tenantId, fromEmail)
  ├─ tenant té smtp_config actiu i verificat?
  │    └─ SÍ → transport: Nodemailer SMTP (credencials del Vault)
  ├─ tenant té custom domain verificat?
  │    └─ SÍ → transport: Resend API amb domini del tenant
  └─ fallback → transport: Resend API amb domini de plataforma
```

### Nova taula: `data.tenant_smtp_configs`

```sql
CREATE TABLE data.tenant_smtp_configs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  is_active       boolean NOT NULL DEFAULT false,
  smtp_host       text NOT NULL,
  smtp_port       int  NOT NULL DEFAULT 587,
  smtp_user       text NOT NULL,
  -- La password s'emmagatzema al Vault de Supabase (pgsodium), mai en plaintext.
  -- El vault_secret_id referencia vault.secrets.id
  vault_secret_id uuid,
  encryption_tls  text NOT NULL DEFAULT 'starttls' CHECK (encryption_tls IN ('none','starttls','ssl')),
  from_email      text NOT NULL,
  from_name       text,
  verified_at     timestamptz,  -- NULL fins que es fa test_connection amb èxit
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id)  -- un sol SMTP per tenant (simplifica la cascada)
);
```

### Nova Edge Function: `configure-byos-smtp`

Estructura idèntica a `configure-byos` (storage):

| Pas | Acció |
|-----|-------|
| 1 | Autenticar usuari (JWT) |
| 2 | Autoritzar: `role = 'owner'` del tenant |
| 3 | Validar body: host, port, user, password, from_email |
| 4 | **Test de connexió SMTP** (veure més avall) |
| 5 | Guardar password al Vault via `vault.create_secret()` |
| 6 | Upsert a `data.tenant_smtp_configs` amb `vault_secret_id` |
| 7 | Marcar `verified_at = now()` |

**DELETE** → desactiva (`is_active = false`) en lloc d'esborrar, per preservar historial.

### Test de connexió SMTP

Abans de desar, cal verificar que les credencials funcionen:

```typescript
// Deno + npm:nodemailer
import nodemailer from "npm:nodemailer";

const transporter = nodemailer.createTransport({
  host: body.smtp_host,
  port: body.smtp_port,
  secure: body.encryption_tls === "ssl",
  auth: { user: body.smtp_user, pass: body.smtp_password },
});

await transporter.verify(); // llança excepció si falla
```

Errors comuns i com mapejar-los:

| Error | Causa probable | Missatge a l'usuari |
|-------|---------------|---------------------|
| `ECONNREFUSED` | Port bloquejat o host incorrecte | "No s'ha pogut connectar al servidor SMTP" |
| `ETIMEDOUT` | Firewall o host incorrecte | "Temps d'espera superat" |
| `535 Authentication failed` | Credencials incorrectes | "Usuari o contrasenya incorrectes" |
| `530 5.7.0 Authentication required` | Office 365 SMTP bàsic desactivat | "El servidor requereix autenticació moderna (OAuth2)" |

### Modificació a `process-email-queue`

Afegir funció `resolveTransport` al worker:

```typescript
async function resolveTransport(tenantId: string): Promise<Transport> {
  // 1. Comprovar SMTP config
  const { data: smtpConfig } = await adminClient
    .from("tenant_smtp_configs")
    .select("*")
    .eq("tenant_id", tenantId)
    .eq("is_active", true)
    .not("verified_at", "is", null)
    .maybeSingle();

  if (smtpConfig) {
    const password = await getVaultSecret(smtpConfig.vault_secret_id);
    return { type: "smtp", config: { ...smtpConfig, password } };
  }

  // 2. Comprovar custom domain
  const { data: domain } = await adminClient
    .from("email_domains")
    .select("domain, default_from_email")
    .eq("tenant_id", tenantId)
    .eq("is_primary", true)
    .eq("verification_status", "verified")
    .maybeSingle();

  if (domain) {
    return { type: "resend_custom_domain", domain };
  }

  // 3. Fallback plataforma
  return { type: "resend_platform" };
}
```

---

## Consideracions de seguretat

- La password SMTP **mai** es desa a `data.*` en plaintext. Sempre via `vault.create_secret()`.
- Cal xifrar la password **abans** d'enviar-la a la RPC — usar HTTPS és suficient, però
  considerar `pgsodium.crypto_aead_det_encrypt` per doble capa si el compliance ho requereix.
- Auditar tots els canvis a `tenant_smtp_configs` a `data.audit_logs` amb acció `SMTP_CONFIG_UPDATED`.
- El test de connexió s'ha de fer des de l'Edge Function (servidor), no des del browser,
  per evitar exposar credencials al client.

---

## Advertències d'implementació

### Office 365 / Microsoft 365
Microsoft ha deprecat SMTP bàsic (user+password) per defecte des del 2023.
Els tenants amb O365 necessitaran:
- Activar "SMTP AUTH" explícitament a l'admin de Microsoft 365, o
- Usar OAuth2 (Client Credentials flow) — molt més complex d'implementar.

Recomanació: documentar-ho clarament a la UI quan l'usuari posa un host `smtp.office365.com`
o `outlook.office365.com`.

### Gmail / Google Workspace
Google va eliminar el suport de "Less Secure Apps" el 2022.
Cal usar **App Passwords** (2FA activat al compte) o OAuth2.

### Reputació i fallback
Si el servidor SMTP del tenant falla durant l'enviament:
- El Worker ha de marcar el correu com `failed` i encuar un reintent.
- **NO fer fallback automàtic a Resend** per correus de negoci del tenant — el tenant
  espera que surti del seu domini.
- Sí fer fallback a Resend **únicament** per correus de sistema (reset password, invitació)
  si el SMTP falla més de N vegades consecutives → notificar l'owner del tenant.

---

## Addon de pla

Igual que `custom_domains_enabled` a `data.email_configs`, afegir:

```sql
ALTER TABLE data.email_configs
  ADD COLUMN byos_smtp_enabled boolean NOT NULL DEFAULT false;
```

Activable des de l'admin-portal per tenant. El check es fa a `configure-byos-smtp`
igual que `manage-email-domain` comprova `custom_domains_enabled`.

---

## Fitxers a crear/modificar

| Fitxer | Acció |
|--------|-------|
| `supabase/functions/configure-byos-smtp/index.ts` | Crear (nova Edge Function) |
| `supabase/functions/process-email-queue/index.ts` | Modificar — afegir `resolveTransport()` |
| `supabase/migrations/XXXXXXXX_byos_smtp.sql` | Crear — taula + RLS + audit trigger |
| `apps/tenant-portal/src/features/email/` | Afegir UI de configuració SMTP |
| `apps/admin-portal/` | Afegir toggle `byos_smtp_enabled` per tenant |
| `docs/email.md` | Afegir secció BYOS SMTP al diagrama de flux |
