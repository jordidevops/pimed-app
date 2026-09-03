Com que la vostra aplicació està pensada perquè l'utilitzin usuaris externs a la vostra pròpia organització (els vostres *tenants*), Google és molt estricte. Aquí teniu com funciona exactament el procés i què us demanaran:

### 1. La Pantalla de Consentiment (OAuth Consent Screen)
És un pas completament innegociable. Perquè l'aplicació pugui interactuar amb l'API de Google Calendar en nom d'un *tenant*, primer haureu de configurar l'OAuth Consent Screen a la Google Cloud Console. Aquesta és la finestra on l'usuari veu el vostre logotip i se li pregunta: *"L'aplicació X vol accedir al teu calendari, hi estàs d'acord?"*.

### 2. La Verificació de l'Aplicació
Com que sou una plataforma SaaS i interactuareu amb calendaris d'usuaris aliens a la vostra organització, **Google us exigirà passar per un procés de verificació oficial**. 

Això passa perquè els permisos (*scopes*) necessaris per llegir o escriure esdeveniments al calendari (`auth/calendar` o `auth/calendar.events`) estan catalogats per Google com a **Permisos Sensibles (Sensitive Scopes)**. 

Per aconseguir l'aprovació i ser una aplicació verificada, us demanaran complir aquests requisits:
* **Mínim privilegi:** Només heu de demanar els permisos estrictament necessaris. Si només voleu afegir esdeveniments, no demaneu permís per llegir/esborrar correus de Gmail, per exemple.
* **Domini verificat:** La pàgina d'inici de la vostra aplicació i la política de privacitat han d'estar allotjades en un domini que pugueu demostrar que és vostre.
* **Política de Privacitat pública:** Ha d'estar penjada a la vostra web i explicar clarament què fareu amb les dades del calendari de l'usuari.
* **Vídeo demostratiu:** És el requisit que més sorprèn. Haureu de gravar un vídeo (i penjar-lo a YouTube de forma oculta) ensenyant com un usuari fa clic al botó d'integrar, com passa per la pantalla de consentiment (on s'ha de veure el Client ID a la barra del navegador) i finalment mostrar com funciona la integració dins del vostre *tenant-portal* (com es crea l'esdeveniment).

### I com ho feu per desenvolupar sense estar verificats?
No cal que patiu per la verificació mentre programeu la funcionalitat. Mentre esteu en fase de desenvolupament:
1.  Podeu mantenir la configuració de la pantalla de consentiment en estat de **"Testing"** (Proves).
2.  Això us permetrà autoritzar l'accés a l'API a un màxim de **100 usuaris de prova** (que prèviament heu d'haver donat d'alta manualment al panell de Google Cloud). 
3.  Aquests usuaris (que sereu vosaltres mateixos provant) veuran un avís gegant que diu *"L'aplicació no està verificada"*, però si hi fan clic podran avançar i el codi funcionarà igualment.

En resum: Podeu programar tota la integració de Calendar en local i en *staging* sense demanar permís a ningú. Però just abans de llançar la funcionalitat a producció per als clients reals, haureu de preparar els textos legals, gravar el vídeo i demanar a Google que us verifiqui l'app.