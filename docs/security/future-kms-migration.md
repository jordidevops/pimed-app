# Migració futura a KMS extern

## Motivació

Supabase Vault és adequat per a secrets d'integració BYO. Un KMS extern (GCP, AWS, Azure) aporta:

- Claus al compte del client
- Auditoria per operació (CloudTrail)
- HSM / FIPS per compliance

## Passos de migració (alto nivell)

1. Implementar `GcpKmsProvider` / `AwsKmsProvider` a `kms-provider.ts`.
2. Dual-read: provar decrypt KMS vs Vault en paral·lel (shadow mode).
3. Re-encriptar secrets actius amb script batch (finestra de manteniment).
4. Nous secrets només via KMS; Vault en mode lectura fins a buidar.
5. Desactivar Vault per nous secrets.

## Requisits previs (GCP exemple)

- Compte GCP + Key Ring per entorn (dev/staging/prod)
- Service Account amb `cloudkms.cryptoKeyVersions.useToEncrypt/Decrypt`
- Secret de SA a Edge Functions

Veure [cost-analysis.md](./cost-analysis.md) per estimacions.
