# Signing Ops: què tenim i què podem afegir després

Document planer per producte i ops. No tanca Gate F ni implica un centre de seguretat complet.

## Què tenim avui

A l’admin-portal, `/dashboard/signing-ops` (i el tab Firmes del tenant) serveix per **operar el dia a dia**:

- Veure errors de firma / PDF i marcar-los com a resolts.
- Veure si el job que recupera PDFs firmats (reconcile) va bé, quant de backlog hi ha, i executar-lo a mà.
- Veure anomalies agregades (firmes encallades, pics, comptadors de `rate_limited`).
- Estadístiques senzilles (nativa vs DocuSeal, crèdits).

A dalt de la pàgina hi ha el panell **«Cal atenció»**: interpreta els nombres amb uns llindars fixos i et diu què mirar (o «Tot en ordre»).  
Cal **obrir l’admin** per veure-ho: no et truqueja sol.

## Què ens falta i per a què serviria

### Avisos al mòbil / PagerDuty (o Slack)

**Què és:** que el sistema et noti quan alguna cosa va malament (reconcile fallat, cua massa gran), sense haver d’obrir el panell.

**Per a què serveix:** nits, caps de setmana, o quan ningú mira l’admin cada hora.

**Quan val la pena:** quan hi ha algú de guàrdia (on-call) i un canal (PagerDuty, Slack) ja en ús. Si no, el panell «Cal atenció» sol ser suficient.

### Fitxa d’una firma (dades de la persona)

**Què és:** obrir una submission / request concreta i veure nom, email, estat, historial d’events i context del document.

**Per a què serveix:** tickets de suport («el client diu que ha signat i no es veu»).

**Quan val la pena:** quan el volum de consultes individuals ho justifica. Cal tractar-ho com a dades personals (accés limitat, traça d’auditoria). Avui teniu agregats i logs d’ops, no aquesta fitxa.

### Cancel·lar o reenviar des d’admin

**Què és:** un botó per aturar un sobre DocuSeal o forçar un reenviament / nou intent des de plataforma.

**Per a què serveix:** incidents greus quan el tenant o el flux automàtic estan bloquejats.

**Quan val la pena:** quan el reconcile automàtic i el flux del producte (canvi de provider, decline) no basten. És potència perillosa: es pot deixar el client a mig firmar; cal confirmació i registre de qui ho ha fet.

### Límits d’abús configurables des de l’admin

**Què és:** pujar/baixar el rate-limit de `/sign` o bloquejar temporalment un tenant/IP des de la UI.

**Per a què serveix:** pics d’abús o proves controlades.

**Quan val la pena:** si veieu atacs o molts 429 reiterats. Avui el límit ja existeix al producte; a Signing Ops només veieu el **comptador** (`rate_limited` 24h) i l’avís informatiu al panell.

## Resum

| Necessitat | Avui | Després (si cal) |
|------------|------|------------------|
| Saber si hi ha foc | «Cal atenció» a l’admin | Avisos PagerDuty/Slack |
| Ajudar un client concret | Logs + tenant Firmes | Fitxa amb dades de la persona |
| Desbloquejar un cas greu | Reconcile global | Cancel / reenviament per cas |
| Frenar abús | Comptador + límit de producte | Controls des de l’admin |

Prioritat natural si cal ampliar: **avisos** → **fitxa de suport** → **cancel** → **límits configurables**.
