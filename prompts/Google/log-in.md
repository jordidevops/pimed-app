El correu electrònic, el nom i la foto de perfil (els permisos `email`, `profile` i `openid`) estan catalogats per Google com a **Permisos No Sensibles (Non-sensitive scopes)**.

Això vol dir que, independentment de si utilitzes Firebase, Supabase o el teu propi backend, **NO cal passar pel procés de verificació estricte** si només vols posar el botó clàssic d'inici de sessió. T'estalvies gravar el vídeo de YouTube i l'espera de la revisió manual.

Perquè qualsevol usuari pugui fer login a la teva app sense veure l'avís de "Pantalla no segura", només necessites complir dos requisits molt bàsics a la Google Cloud Console:

1.  Passar l'estat de l'aplicació de "Testing" a **"In production"**.
2.  Posar un **enllaç real a la Política de Privacitat** de la teva web.

### ⚠️ Alerta: La "trampa" del logotip

Hi ha un petit detall que fa caure a molts desenvolupadors: **Si puges el teu logotip** a la configuració de la pantalla de consentiment (OAuth Consent Screen), Google forçarà automàticament el procés de verificació, fins i tot si només demanes l'email. 

El truc que fa tothom quan arrenca un SaaS és **deixar el camp del logotip buit**. D'aquesta manera, l'aplicació passa a producció de forma instantània i els usuaris ja poden fer login. Només veuran el nom de la teva app (ex: "Tenant Portal") però sense icona.

### L'estratègia intel·ligent

El millor que pots fer és anar per fases:
1.  **Ara:** Integres el botó de Google només per fer login (`email` i `profile`). Poses l'app en producció sense logotip i comences a captar usuaris ràpidament sense cap bloqueig burocràtic.
2.  **Més endavant:** Quan ja tinguis la funcionalitat de Google Calendar a punt per llançar, afegeixes el permís sensible (`calendar.events`), puges el logotip per donar més confiança i, llavors sí, envies l'aplicació a verificar.

---

