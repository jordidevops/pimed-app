# Anàlisi de costos — KMS i Vault

## Comparativa (ordre de magnitud)

| Backend | Cost operatiu | Gestió clau | Auditoria |
|---------|---------------|-------------|-----------|
| **Supabase Vault (pgsodium)** | Inclòs al pla Supabase | Supabase | Limitada |
| **GCP Cloud KMS** | ~$0.06 / 10.000 ops encrypt/decrypt | Client (GCP) | CloudTrail |
| **AWS KMS** | ~$0.03 / 10.000 ops + $1/clau/mes | Client (AWS) | CloudTrail |
| **Azure Key Vault** | ~$0.03 / 10.000 ops | Client (Azure) | Azure Monitor |

## Estimació volum (ERP multi-tenant petit-mitjà)

| Operació | Volum mensual estimat |
|----------|----------------------|
| `get_tenant_secret` (AI) | 50.000–500.000 |
| Twilio/SMS | 5.000–50.000 |
| BYOS storage | 10.000–100.000 |
| Webhooks | 1.000–20.000 |
| **Total decrypt** | **~100.000–700.000/mes** |

### Cost GCP KMS (si es migrés tot)

700.000 ops / 10.000 × $0.06 ≈ **$4.20/mes** (només operacions, sense claus ni HSM).

El cost KMS no és el factor limitant; ho són compliance, auditoria i gestió de claus enterprise.

## Quan migrar a KMS extern

- Client enterprise exigeix claus al seu compte cloud
- Auditoria SOC2/ISO amb traçabilitat per operació de xifrat
- Regulació sectorial (HSM, FIPS 140-2)
- **No** cal migrar només per cost en volums actuals

## Recomanació V1

Mantenir Vault. Monitoritzar `secret_access_log` per volum real abans de qualsevol migració.
