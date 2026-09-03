# Prompt: Estudi de Governança de la IA pròpia (AI Act)

Actua com el mateix Principal Engineer que ha treballat en els mòduls anteriors d'aquesta app (Qualitat ISO, Transparència Retributiva, Accessibilitat). Mateix mètode: auditoria del codi real primer, decisions amb criteris explícits després, pla al final.

## Objecte d'aquest mòdul

A diferència dels anteriors, aquí l'objecte de compliment **no és el tenant, sou vosaltres mateixos**: qualsevol funcionalitat d'IA que la pròpia app ofereixi (agents, recomanacions, priorització automàtica de tasques, assistents de contractació, xatbots, generació de contingut) queda subjecta al Reglament (UE) 2024/1689 (AI Act). Això té una segona capa d'interès estratègic: la infraestructura d'auditoria i traçabilitat que ja heu construït per al mòdul ISO (registre d'accions, evidències, aprovacions) és reutilitzable gairebé directament per a **registre i governança de sistemes d'IA**. Explora aquesta reutilització explícitament, no ho tractis com un mòdul aïllat.

## Context legal (verifica sempre l'estat més actualitzat abans de prendre cap data com a definitiva; aquesta matèria ha canviat recentment)

- El AI Act és en vigor des de l'1 d'agost de 2024, amb aplicació esglaonada. <cite index="38-1">Les pràctiques prohibides són exigibles des del 2 de febrer de 2025 i les obligacions de models d'IA de propòsit general des del 2 d'agost de 2025; cap d'aquestes dues dates s'ha mogut.</cite>
- <cite index="38-1">El 29 de juny de 2026, el Consell de la UE va aprovar definitivament el "Digital Omnibus on AI", que ajorna 16 mesos les obligacions dels sistemes d'IA d'alt risc independents (Annex III) i 12 mesos les integrades en productes regulats (Annex I).</cite> <cite index="41-1">Les obligacions d'alt risc de l'Annex III (independents) queden ajornades al 2 de desembre de 2027, i les de l'Annex I (integrades) al 2 d'agost de 2028.</cite>
- **Important i urgent**: <cite index="44-1">el 2 d'agost de 2026 (avui) entren en vigor les obligacions de transparència de l'article 50</cite> — que **no s'han ajornat**. Això vol dir que, encara que l'obligació d'"alt risc" completa s'hagi retardat, **l'obligació d'informar l'usuari que està interactuant amb un sistema d'IA (i marcar contingut generat per IA) ja és exigible ara mateix**.
- Els sistemes d'IA destinats a contractació/selecció de personal, decisions sobre condicions de la relació laboral, promoció o acomiadament, assignació de tasques basada en comportament/trets individuals, o supervisió/avaluació de rendiment, es classifiquen com a **alt risc (Annex III, punt 4)** quan arribi la data d'aplicació. <cite index="42-1">Els sistemes ja al mercat abans de la data d'aplicació poden acollir-se a un règim de "grandfathering" i evitar les obligacions completes fins que hi hagi una "modificació substancial"</cite> — per això dissenyar-ho bé ara (encara que l'obligació estricta trigui) evita haver-ho de refer el 2027.

## FASE 0 (obligatòria): Inventari real de la IA que ja existeix a l'app

No donis per fet res. Fes un inventari exhaustiu al codi de:

- Tota funcionalitat que faci servir un model d'IA (crides a APIs de LLM, classificadors, sistemes de recomanació, scoring automàtic), incloent-hi les que no es venen explícitament com "IA" de cara al tenant (per exemple, una priorització automàtica de tasques, un motor de detecció d'anomalies, un assistent de redacció).
- Per a cadascuna, identifica: quina decisió pren o suggereix, si actua de manera autònoma o només proposa i un humà decideix, i si afecta persones treballadores del tenant (contractació, avaluació, assignació de feina) — aquest últim punt és el que activa la classificació d'alt risc.
- Si existeix ja algun registre o inventari de "quines funcionalitats d'IA tenim" en qualsevol forma (documentació interna, feature flags), o si aquest inventari s'ha de crear des de zero.

## 1. Classificació de cada sistema d'IA identificat

Per a cada sistema de l'inventari, classifica'l (prohibit / alt risc per motius laborals / transparència únicament / cap obligació específica) i justifica-ho. Distingeix clarament el vostre doble paper possible:

- **Com a proveïdor**: si oferiu als tenants una funcionalitat d'IA destinada a l'àmbit laboral (per exemple, un assistent de cribratge de candidatures), sou proveïdors d'un sistema d'alt risc encara que el tenant sigui qui l'utilitza.
- **Com a desplegador indirecte**: si el tenant configura o entrena l'ús d'una funcionalitat genèrica (per exemple, un motor de priorització general) específicament per a decisions laborals, cal aclarir qui assumeix quina part de l'obligació.

## 2. Registre d'IA (AI Registry) com a infraestructura reutilitzable

Dissenya una entitat/mòdul de **registre de sistemes d'IA**, inspirat directament en el patró ja construït per a documents/evidències ISO:

- Fitxa per sistema d'IA: propòsit, dades d'entrada, model/proveïdor subjacent, nivell de risc assignat, data de classificació, responsable.
- Registre d'activitat de decisions rellevants preses o suggerides pel sistema (no cal registrar cada crida, sí les que afecten una persona de manera significativa), per poder demostrar supervisió humana efectiva.
- Mecanisme de "modificació substancial": com detecteu i registreu quan un canvi a un sistema d'IA existent el fa perdre l'acollida al règim transitori (rellevant per al 2027, cal preparar-ho ara).

## 3. Obligacions de transparència (article 50) — implementació immediata

Com que aquesta obligació ja és exigible avui, prioritza-la per davant de la resta:

- On i com s'informa l'usuari (tenant o el seu treballador) que està interactuant amb un sistema d'IA i no amb una persona.
- Com es marca contingut generat per IA que es presenti al tenant o als seus clients finals (documents, respostes, recomanacions redactades automàticament).

## 4. Supervisió humana per a funcionalitats sensibles

Per a qualsevol funcionalitat identificada amb potencial d'alt risc (contractació, avaluació, assignació de tasques), especifica el mecanisme concret de supervisió humana: qui ha d'aprovar abans que la suggerència de la IA tingui efecte, i com queda registrat que hi ha hagut supervisió real (no un clic automàtic de "acceptar").

## 5. Oportunitat de producte

Si el disseny del registre d'IA i la traçabilitat de supervisió humana queda prou genèric, avalua si es pot oferir com a **mòdul per als tenants** que construeixin les seves pròpies funcionalitats d'IA (per exemple, si un tenant fa servir IA per filtrar candidatures), reutilitzant la mateixa infraestructura. No ho desenvolupis en detall, només indica si té sentit i per què.

## Format de resposta

Comença per l'inventari real (Fase 0) abans de res més. Marca explícitament quines decisions són tècniques (les pots prendre tu) i quines són legals/de negoci (classificació d'alt risc d'un sistema concret, si assumiu el rol de proveïdor) i que, per tant, haurien de confirmar-se amb assessorament legal abans d'implementar-les com a definitives.