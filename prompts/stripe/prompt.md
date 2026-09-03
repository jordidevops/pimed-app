Actua com un arquitecte sènior de programari especialitzat en SaaS multitenant, Stripe Billing i Supabase.

Vull dissenyar la integració completa de Stripe per a una aplicació SaaS construïda amb:

- Supabase
- PostgreSQL
- Auth de Supabase
- Frontend React/Vite
- Arquitectura multitenant
- Arquitectura multi-site
- Rols i permisos per tenant i site

Necessito que generis un PLA D'INTEGRACIÓ COMPLET i pràctic.

L'aplicació té aquesta estructura conceptual:

- Un usuari pot pertànyer a diversos tenants
- Cada tenant pot tenir múltiples sites
- Els permisos es gestionen per tenant/site
- Cada tenant tindrà la seva subscripció
- Alguns límits es poden aplicar: 
- nombre d'usuaris 
- nombre de sites 
- emmagatzematge 
- funcionalitats premium
- Pot haver-hi addons o mòduls extra
- Volem suportar: 
- proves gratuïtes 
- upgrades/downgrades 
- cancel·lacions 
- pagaments fallits 
- facturació automàtica 
- customer portal 
- cupons/descomptes 
- impostos/VAT si és recomanable
- Volem mantenir la lògica alineada amb Stripe Billing modern

Vull que proposis una arquitectura moderna basada en:

- Stripe Checkout
- Stripe Billing
- Webhooks
- Stripe Customer Portal
- Stripe Sync Engine (si ho recomanes)
- Supabase Edge Functions (si s'aplica)
- RLS policies
- PostgreSQL schema design

Necessito que el resultat inclogui:

# 1. Arquitectura recomanada

Explica:
- flux complet de pagament
- flux d'alta de tenant
- flux d'upgrade/downgrade
- flux de cancel·lació
- sincronització de Stripe amb Supabase
- què ha de viure a Stripe i què a la nostra DB

# 2. Model de dades recomanat

Proposa taules SQL o estructura conceptual per a:
- tenants
- sites
- memberships
- plans
- subscriptions
- billing_customers
- feature_flags
- usage_limits
- invoices
- payment_events
- audit logs

Indica:
- claus primàries
- relacions
- índexs importants
- quines dades vénen de Stripe
- quines dades són internes

# 3. Estratègia multi-tenant

Explica:
- com associar tenants ↔ customers de Stripe
- si fer servir un customer per tenant
- com manejar usuaris pertanyent a diversos tenants
- com evitar problemes de seguretat entre tenants

# 4. Integració Stripe

Detall:
- productes i preus a Stripe
- monthly/yearly plans
- metered billing si s'aplica
- addons
- trials
- cupons
- customer portal
- webhooks necessaris
- idempotència

# 5. Stripe Sync Engine

Vull que analitzis:
- si val la pena fer-lo servir
- avantatges i inconvenients
- com conviuria amb taules pròpies
- estratègia híbrida recomanada
- quines taules sincronitzaries
- com evitar duplicitat/conflictes

# 6. Seguretat

Inclou:
- RLS examples
- validacions crítiques
- protecció de webhooks
- separació tenant/site
- maneig segur de rols
- protecció contra manipulació del frontend

# 7. Escalabilitat

Explica:
- com escalar a milers de tenants
- estratègia d'índexs
- esdeveniments asíncrons
- cues/retries
- observabilitat
- auditoria

# 8. Estratègia d'implementació

Dóna'm:
- roadmap per fases
- MVP mínim
- què fer primer
- què deixar per després
- riscs comuns
- antipatrons

# 9. Codi d'exemple

Inclou exemples de:
- SQL schema
- Edge Functions
- Webhook handlers
- creació de checkout session
- validació de permisos
- sincronització de subscripcions

# 10. Recomanació final

Vull una recomanació clara:
- arquitectura ideal
- què evitar
- què simplificar
- què faries en producció el 2026

Vull una resposta extremadament pràctica i orientada a producció real.
Evita teoria innecessària.
Prioritza simplicitat, mantenibilitat i escalabilitat.