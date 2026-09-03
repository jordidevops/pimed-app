DONE
Tens tota la raó, i és un detall crític que sovint s'oblida fins a l'últim moment. Si la plataforma és multilingüe (Català, Castellà, Anglès, etc.), enviar un correu de benvinguda en l'idioma equivocat trenca completament l'experiència de l'usuari.

A nivell arquitectònic, tenim dues maneres d'abordar-ho:
1.  **Multiplicar files:** Una fila per idioma (ex: `welcome-ca`, `welcome-en`). És fàcil d'entendre, però fa que el Copy-on-Write i el manteniment de Layouts es converteixi en un malson (el tenant hauria de clonar 3 plantilles diferents).
2.  **Camp JSONB de Traduccions (L'estàndard SaaS):** Mantenim 1 sola fila per event (ex: `welcome-email`), però la plantilla inclou un camp `translations` amb les versions en altres idiomes. Això manté la interfície neta i la resolució d'errors molt més robusta.

Implementarem l'opció 2 perquè encaixa com un guant amb el disseny que ja tenim.

Aquí tens el pla d'acció i el prompt exacte per adaptar el sistema.

### Com funcionarà el Model Multilingüe?

* **A la Base de Dades:** Les columnes actuals (`subject_template`, `html_body_template`) actuaran com a **idioma principal / fallback** (per exemple, el català). Afegirem una nova columna `translations JSONB` que guardarà la resta d'idiomes.
    ```json
    {
      "es": { "subject": "Bienvenido", "html": "<p>Hola</p>", "text": "Hola" },
      "en": { "subject": "Welcome", "html": "<p>Hello</p>", "text": "Hello" }
    }
    ```
* **A l'API (Enqueue):** El payload de `enqueue_email` acceptarà un camp `locale: 'es'`. Si existeix, la base de dades llegirà el JSON. Si no existeix la traducció, farà un *fallback* automàtic a l'idioma principal de la columna nativa.
* **Al Frontend (Editor):** L'editor de plantilles tindrà un selector d'idioma. L'usuari edita l'HTML, i depenent de l'idioma seleccionat, es guarda al camp principal o dins del JSON de traduccions.

---

### Prompt per a la IA: Implementació Multilingüe de Plantilles

> **Rol:** Senior SaaS Architect & Frontend Developer.
>
> **Objectiu:** Afegir suport multilingüe a les plantilles d'email utilitzant un camp JSONB de traduccions, permetent que un sol event/layout contingui múltiples idiomes amb un fallback elegant.
>
> **Tasques a realitzar:**
>
> **1. SQL (`20260427000008_email_translations.sql` o afegit a l'actual):**
> * Afegeix la columna `translations jsonb DEFAULT '{}'::jsonb` a `data.email_templates`.
> * Actualitza la vista `api.email_templates` per exposar aquest nou camp.
>
> **2. Lògica de Resolució (`api.enqueue_email`):**
> * Extreu la variable `v_locale := COALESCE(payload ->> 'locale', 'ca');` (assumint 'ca' com a idioma per defecte/base).
> * Modifica la part on s'assignen `v_subject`, `typedLog.html_body` i `typedLog.text_body`.
> * Lògica de fallback per idioma: Si `v_locale` no és el base, busca dins de `v_template_row.translations -> v_locale`. Si no hi ha res, utilitza els camps base (`subject_template`, `html_body_template`, etc.).
>   *Exemple SQL:*
>   `v_subject := COALESCE(v_template_row.translations -> v_locale ->> 'subject', v_template_row.subject_template);`
>
> **3. Actualització del Worker (`supabase/functions/process-email-queue/index.ts`):**
> * Quan el Worker resolgui el Layout (si n'hi ha), ha de fer la mateixa operació: mirar si la plantilla del Layout té el `locale` guardat a `email_logs.metadata->>'locale'` (o on decideixis passar-ho) i extreure l'HTML traduït, fent fallback a l'HTML base del layout.
> * *Nota per a l'enqueue:* Assegura't de guardar el `locale` enviat al payload dins de `email_logs.metadata` perquè el Worker sàpiga en quin idioma renderitzar el layout.
>
> **4. Modificació de Types i Mutaions (`types.ts`, `useEmailTemplateMutations.ts`):**
> * Afegeix `translations: Record<string, { subject?: string, html?: string, text?: string }>` a `EmailTemplate` i `EmailTemplateUpdate`.
>
> **5. UI - Editor de Plantilles (`EmailTemplateEditor.tsx`):**
> * Afegeix un selector d'idioma (ex: Toggle Group o Select amb 'CA', 'ES', 'EN') a la part superior de la pestanya "Editar".
> * **Gestió d'Estat Local:** Quan l'usuari canvia d'idioma, els `Input` i `textarea` de l'assumpte i els cossos HTML/TXT han de mostrar els valors corresponents (del camp base si és 'CA', o de l'objecte `translations` si és 'ES' o 'EN').
> * En desar, reconstrueix l'objecte i envia-ho al backend a través de la mutació.

---

Amb aquest enfocament, mantindràs el teu Admin Portal net (un llistat d'events, no una infinitat de files repetides) i quan l'equip de màrqueting o el tenant vulguin traduir el correu de "Reset Password", ho faran tot des d'una mateixa pantalla centralitzada.

Quins són els idiomes oficials que has de suportar a la plataforma en aquesta primera fase per deixar-los ben definits als *selectors* del frontend?