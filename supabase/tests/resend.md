### Adreces de prova oficials de Resend
* **Rebot (Bounce):** Envia el correu de prova a `bounced@resend.dev`. Aquesta adreça simularà el rebot (bounce) immediatament.
* **Queixa per Spam (Complaint):** Envia a `complained@resend.dev`. Simularà l'esdeveniment en què l'usuari final ha marcat el teu correu com a correu brossa.
* **Bloquejat (Suppressed):** Envia a `suppressed@resend.dev`. Simularà un enviament a una adreça que Resend ja té bloquejada per evitar danys a la infraestructura.
* **Lliurat (Delivered):** Envia a `delivered@resend.dev`. Simularà un lliurament ideal amb èxit.








# Webhook per la function resend-webhook

## Configuració necessària

### A) Configurar el Webhook a Resend Dashboard

1. Accedeix a **[Resend Dashboard](https://resend.com) → Webhooks → Add Webhook**.
2. **Endpoint URL:**
   ```
   https://<PROJECT_REF>.supabase.co/functions/v1/resend-webhook
   ```
3. **Events a subscriure:** `email.delivered`, `email.bounced`, `email.complained`, `email.delivery_delayed`, `email.suppressed`.
4. Copia el **Signing Secret** generat per Resend (format `whsec_...`).

### B) Afegir `RESEND_WEBHOOK_SECRET` a Supabase

**Opció 1 — Dashboard (producció):**
> Supabase Dashboard → Project → Edge Functions → **Manage secrets** → `New secret`
> - **Name:** `RESEND_WEBHOOK_SECRET`
> - **Value:** `whsec_xxxxxxxxxxxxxx` (copiat de Resend)

**Opció 2 — CLI (local dev):**
Afegir al fitxer .env:
```
RESEND_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxxx
```

**Opció 3 — Supabase CLI (secrets remots):**
```bash
supabase secrets set RESEND_WEBHOOK_SECRET=whsec_xxxxxxxxxxxxxx
```

## Test en local

Provar webhooks en local sempre té un petit repte tècnic: com que la nostra Edge Function valida estrictament la **signatura criptogràfica (Svix)**, no podem fer un simple `curl` des del terminal (perquè fallaria la verificació de seguretat).

La solució estàndard i més professional a la indústria és fer servir una eina anomenada **ngrok** (o similar, com Cloudflare Tunnels) per crear un "túnel" que connecti l'API de Resend directament amb el teu ordinador local.

    scoop install ngrok

Aquí tens el pas a pas exacte per fer-ho:

### Pas 1: Exposar el teu port local a Internet

Supabase en local serveix les Edge Functions al port `54321`. Necessitem que Resend pugui enviar dades a aquest port.

1. Si no tens **ngrok**, descarrega'l i instal·la'l des de [ngrok.com](https://ngrok.com/).
2. Obre un terminal nou i executa:
   ```bash
   ngrok http 54321
   ```
3. Ngrok et donarà una URL pública segura (per exemple: `https://a1b2-c3d4.ngrok-free.app`). **Copia aquesta URL.**

### Pas 2: Configurar el Webhook temporal a Resend

1. Ves al dashboard de Resend → **Webhooks** → **Add Webhook**.
2. A l'Endpoint URL, enganxa la teva URL de ngrok i afegeix-hi la ruta de la funció. Ha de quedar així:
   `https://a1b2-c3d4.ngrok-free.app/functions/v1/resend-webhook`
3. Selecciona els esdeveniments (com a mínim `email.bounced` i `email.delivered`).
4. Guarda'l i **copia el Signing Secret** (`whsec_...`) que et generarà aquest webhook específic.

### Pas 3: Configurar l'entorn local de Supabase

Perquè la teva funció local pugui verificar la signatura, necessita conèixer el secret.

1. Crea un fitxer anomenat `.env` dins de la carpeta `supabase/functions/` (si no el tens ja). La ruta seria `supabase/functions/.env`.
2. Afegeix-hi el secret que acabes de copiar de Resend:
   ```text
   RESEND_WEBHOOK_SECRET=whsec_el_teu_secret_del_webhook_ngrok
   ```
3. En un terminal on tinguis el teu projecte, assegura't que Supabase està corrent (`supabase start`) i després aixeca la funció manualment carregant el fitxer `.env`:
   ```bash
   supabase functions serve resend-webhook --env-file ./supabase/functions/.env.local
   ```
   *Veuràs que el terminal es queda escoltant ("Serving resend-webhook...").*

### Pas 4: Disparar la prova!

**Prova real End-to-End**
1. Ves al teu Frontend local (el component "Enviar Correu de Prova").
2. Envia un correu a l'adreça màgica: **`bounced@resend.dev`**.
3. Això generarà un enviament real a la teva BD local amb un `provider_message_id` real.
4. A l'instant, Resend processarà el rebot i trucarà a la teva URL d'ngrok.
5. Ngrok ho passarà a la teva Edge Function local.
6. L'Edge Function verificarà la signatura i farà l'`UPDATE` a la teva base de dades local.
7. Refresca la teva taula d'Historial a l'Admin-Portal local i veuràs el correu marcat en vermell/taronja com a "Rebutjat"!

Un cop acabis de desenvolupar, simplement pots tancar ngrok i esborrar aquest webhook temporal de Resend.

## Error d'autenticació de ngrok

### Opció 1: Configurar ngrok (La més estable i recomanada)
Com que ja el tens instal·lat, només trigaràs un minut i et servirà per sempre:

1. Entra a [https://dashboard.ngrok.com/signup](https://dashboard.ngrok.com/signup) i crea un compte gratuït (pots fer-ho en 1 clic amb Google o GitHub).
2. Un cop dins del dashboard, a la barra lateral esquerra, vés a **Getting Started** -> **Your Authtoken**.
3. Copia la comanda exacta que et mostren allà i executa-la al teu terminal. Serà una cosa així:
   ```bash
   ngrok config add-authtoken 1a2B3c4D5e...el_teu_token_secret...
   ```
4. Un cop guardat, torna a llançar el túnel:
   ```bash
   ngrok http 54321
   ```
Ara sí, et connectarà i et donarà la teva URL segura (`https://...ngrok-free.app`).

---

### Opció 2: L'alternativa ràpida (Sense crear cap compte)
Si no vols registrar-te enlloc ara mateix, com que estàs programant amb Next.js i tens `npm`/`npx` instal·lat al teu ordinador, pots utilitzar una eina gratuïta anomenada **localtunnel**.

1. Al teu terminal, executa directament:
   ```bash
   npx localtunnel --port 54321
   ```
2. Et retornarà una URL a l'instant, semblant a `https://alguna-cosa-aleatoria.loca.lt`.
3. Aquesta és la URL que hauràs de posar al panell de Resend. Recorda afegir-hi el path final: `https://alguna-cosa-aleatoria.loca.lt/functions/v1/resend-webhook`.

*(Nota important sobre localtunnel: A vegades, la primera vegada que fas servir una URL de localtunnel, has d'obrir-la al navegador i fer clic a un botó de confirmació per demostrar que no ets un bot abans que l'API de Resend hi pugui connectar).*

**El meu consell:** Dedica 1 minut a fer l'**Opció 1**. Un cop posat el token d'ngrok al teu ordinador, ja no te'l demanarà mai més, i ngrok és infinitament més ràpid i fiable per atrapar webhooks en local sense talls de connexió.


Executem la funció que procesa la cua la qual enviarà els correus a Resend i aquest llançarà el webhook

En un terminal Linux podem executar la funció

   curl -X POST http://127.0.0.1:54321/functions/v1/process-email-queue \
  -H "Authorization: Bearer eyJhb..." \
  -H "Content-Type: application/json" \
  -d "{}" -i


   Invoke-WebRequest -Uri "http://127.0.0.1:54321/functions/v1/process-email-queue" `
   -Method Post `
   -Headers @{ "Authorization" = "Bearer eyJh" } `
   -ContentType "application/json" `
   -Body "{}"