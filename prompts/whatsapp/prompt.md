***

> Context i Rol:
> Actua com un Arquitecte de Programari expert en Supabase (PostgreSQL), Supabase Edge Functions (Deno + TypeScript) i l'API de WhatsApp Business Cloud (Meta).
>
> Objectiu:
> Vull dissenyar l'arquitectura de base de dades i la logica del backend per integrar WhatsApp al meu SaaS Multi-Tenant sobre Supabase. El sistema ha de ser hibrid:
> 1. Model per defecte (CENTRALIZED): El SaaS utilitza un unic numero oficial. El cost l'assumeix el SaaS i cal aplicar limits d'enviament diaris/mensuals segons el pla del tenant a data.plans.
> 2. Model avancat (BYON - Bring Your Own Number): El tenant connecta el seu propi numero (Embedded Signup de Meta). El cost el paga directament el tenant a Meta, per tant no apliquen limits del SaaS, pero si hem de registrar activitat i cost estimat.
>
> Context del projecte que has de respectar:
> - Esquemes: data.* (taules privades) i api.* (vistes/RPC exposades a PostgREST).
> - Tenant portal: accedeix via api.* amb RLS. No ha de tocar directament data.*.
> - Admin portal: opera sobre data.* amb bypass RLS (prisma_admin).
> - Plans existents a data.plans: name, display_name, max_members, max_storage_mb, max_sites, price_monthly, is_default.
> - Sistema de facturacio existent: data.subscriptions i vista data.billing_summary.
> - Auditoria obligatoria de canvis de cicle de vida via data.audit_logs (action en MAJUSCULES_AMB_GUIO_BAIX).
>
> 1) Model de Dades (en SQL de migracio Supabase, no schema.gql):
> Proposa migracions SQL a supabase/migrations per crear/estendre aquest model en snake_case:
> - Extensio de data.plans amb wa_daily_limit i wa_monthly_limit (integers, nullable per enterprise il.limitat o amb semantica clara).
> - data.tenant_whatsapp_configs (1:1 amb tenant):
>   - tenant_id uuid PK/FK -> data.tenants(id)
>   - model_type text check in ('CENTRALIZED','BYON')
>   - phone_number_id text nullable
>   - access_token_encrypted text nullable (BYON)
>   - business_account_id text nullable
>   - is_verified boolean default false
>   - created_at/updated_at
> - data.whatsapp_logs (registre de missatges):
>   - id uuid PK
>   - tenant_id, site_id nullable, direction, wa_message_id, recipient_number
>   - status ('queued','sent','delivered','read','failed')
>   - model_type ('CENTRALIZED','BYON')
>   - is_billable boolean
>   - cost_in_cents integer
>   - error_code/error_message nullable
>   - provider_payload jsonb
>   - created_at
> - data.whatsapp_usage (agregats per quota):
>   - tenant_id PK
>   - messages_sent_today int
>   - messages_sent_this_month int
>   - day_bucket date
>   - month_bucket date
>   - updated_at
>
> Inclou:
> - Indexos necessaris per consultes de quota i historial.
> - Politques RLS coherents amb el patro del projecte (lectura membre tenant; escriptura owner/manager quan toqui).
> - Vistes/RPC a api.* per a operacions del tenant portal.
> - Triggers o RPC per mantenir consistencia de whatsapp_usage.
> - Triggers/auditoria per a configuracio WhatsApp i events importants.
>
> 2) Logica Backend (Supabase Edge Functions en TypeScript):
> Escriu l'esbos d'una Edge Function send-whatsapp-message amb patro Strategy (o Factory+Strategy) per separar CENTRALIZED i BYON.
>
> Flux requerit:
> - Validar autenticacio de l'usuari amb createUserClient(req).
> - Carregar context tenant + config WhatsApp del tenant (via api.* o RPC).
> - Si model BYON:
>   - enviar a Meta amb phone_number_id/access_token del tenant.
>   - no aplicar limits de data.plans.
> - Si model CENTRALIZED:
>   - consultar limits del pla (data.plans) + estat actual a data.whatsapp_usage.
>   - si excedeix limit diari o mensual, retornar error QUOTA_EXCEEDED.
>   - si no excedeix, enviar a Meta amb credencials master del SaaS.
>   - actualitzar comptadors de quota de forma atomica (RPC o transaccio SQL segura).
> - Registrar sempre el resultat a data.whatsapp_logs.
> - Registrar auditories rellevants a data.audit_logs.
>
> 3) Integracio amb facturacio existent:
> Proposa com encaixar el cost WhatsApp amb el sistema actual:
> - Com relacionar consums WhatsApp amb data.subscriptions/pla actiu.
> - Si recomanes una taula nova de metering (ex: data.billing_usage_events), defineix-la.
> - Com exposar metricas al backoffice (ampliant data.billing_summary o una vista nova data.billing_whatsapp_summary).
> - Diferenciar clarament consum facturable (CENTRALIZED) vs no facturable (BYON).
>
> 4) Seguretat i operativa:
> - No retornar access tokens en cap resposta.
> - Explica on xifrar secrets BYON i com rotar-los.
> - Inclou idempotency_key per evitar duplicats d'enviament.
> - Si proposes enviament async, usa el patro del projecte amb PGMQ + QueueRunner (no cues ad-hoc des de TypeScript).
>
> Format de sortida que vull:
> 1. SQL de migracions (separat per blocs: schema, RLS, api views/RPC, audit).
> 2. Codi TypeScript d'Edge Function send-whatsapp-message (Deno).
> 3. Exemple minim de payload request/response.
> 4. Check-list de proves (quota, BYON, errors Meta, idempotencia).

***

