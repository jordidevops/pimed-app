# STRIPE + HOLDED




Actua com un Arquitecte de Programari Expert, especialista en integracions Fintech (Stripe), sistemes ERP (Holded) i arquitectures B2B Multi-Tenant.

A la nostra aplicació SaaS (PostgreSQL, entorn Serverless) per a pimes, volem implementar un sistema de cobraments "In Situ" per als tècnics, utilitzant una estratègia BYO (Bring Your Own) Stripe per part dels nostres tenants, i sincronitzant la facturació automàticament amb el seu ERP (Holded).

L'objectiu és que un tècnic pugui generar un codi QR / Enllaç de Pagament des de l'app per cobrar una urgència (ex: 250€) i, un cop el client pagui, el sistema actualitzi l'estat i generi la factura legal a l'ERP.

Genera un pla d'arquitectura tècnica detallat per a aquest flux, dividit en les següents fases:

1. Gestió de Credencials BYO Stripe
Dissenya l'esquema SQL (PostgreSQL) per emmagatzemar de forma segura les claus d'API de Stripe de cada tenant (semblant a com guardem les de Holded o OpenAI).

Com hem de gestionar els entorns de prova (Test Mode) i producció (Live Mode) per a aquestes claus dins la nostra base de dades?

2. Generació de Pagaments In Situ (L'App com a TPV)
Dissenya el flux i l'endpoint (ex: POST /api/v1/payments/generate-qr) on l'app sol·licita a Stripe (utilitzant la clau del tenant corresponent) la creació d'un PaymentIntent o un Payment Link.

Proposa com vincular l'ID d'aquest pagament de Stripe (ex: pi_12345) amb el registre de la intervencio_id a la nostra base de dades per no perdre la traçabilitat.

3. Recepció de Webhooks (Inbound) i Sincronització amb Holded (Outbound)
Dissenya el handler del Webhook on rebrem l'esdeveniment payment_intent.succeeded de Stripe.

Defineix el flux asíncron exacte que s'ha d'executar un cop confirmat el pagament:

Marcar la intervenció com a "Cobrada" a la nostra base de dades.

Fer la crida a l'API de Holded per crear la Factura legal amb els impostos desglossats.

Fer la crida a l'API de Holded per crear el "Registre de Pagament" (Payment) associat a aquesta factura, marcant-la com a pagada via Targeta/Stripe.

4. Gestió d'Errors i Registre d'Operacions
Aplica la nostra política d'Errors de Negoci: Qualsevol error en la comunicació asíncrona amb Holded (ex: API Key caducada, NIF del client invàlid) NO ha de fer fallar la recepció del Webhook de Stripe (hem de retornar un 200 OK a Stripe perquè el client ja ha pagat).

Dissenya com el sistema ha de capturar aquests errors d'integració amb l'ERP i guardar-los a la taula tenant_operation_logs (Historial d'Operacions) perquè l'administrador del tenant pugui revisar-ho a la UI i reintentar la creació de la factura manualment.

Si us plau, retorna el pla amb exemples pràctics: l'esquema SQL per a les credencials de Stripe i els registres de pagament, i el pseudocodi/TypeScript del webhook handler que orquestra la validació del pagament i la trucada a Holded, incloent-hi la injecció dels errors al servei de logs.