
El nostre Motor de Notificacions (Dues Vies Separades)
Haureu de programar el vostre backend perquè entengui que existeixen dos "móns" diferents per arribar a l'usuari:

Via 1: L'identificador és el Número de Telèfon (Telecomunicacions)

Eina: Twilio (en mode BYO).

Canals: SMS i WhatsApp.

Cost: Pagament per ús (ho paga el tenant).

Cas d'ús ideal: Avisar el client final (ex: l'administrador de la finca) que el tècnic està en camí.

Via 2: L'identificador és el Token del Dispositiu (Internet)

Eina: Firebase Cloud Messaging (FCM) o OneSignal.

Canals: Notificacions Push (al mòbil del tècnic) i In-App (a l'oficina).

Cost: Gratuït / Assumit pel vostre SaaS.

Cas d'ús ideal: Avisar el vostre propi tècnic que se li ha assignat una nova avaria a la seva ruta.

Aquesta separació és fantàstica a nivell de codi perquè la gestió d'un número de telèfon mòbil (que gairebé mai canvia) és diametralment oposada a la gestió d'un "Token Push" (que canvia cada vegada que l'usuari es descarrega l'app o canvia de telèfon).

Vist que l'arquitectura d'aquest "Motor de Notificacions" haurà de coordinar FCM, Twilio i correus electrònics, vols que redactem el prompt perquè la IA dissenyi l'esquema d'aquest servei unificat al vostre backend, o prefereixes explorar com gestionar la instal·lació de la Web App (PWA) als telèfons dels tècnics?


PROMPT

Actua com un Arquitecte de Programari Expert, especialista en notificacions multicanal, SaaS B2B i entorns Serverless amb PostgreSQL.

A la nostra aplicació necessitem construir un "Motor de Notificacions" (Notification Engine) centralitzat. Aquest servei actuarà com un embut: la resta de l'aplicació li demanarà "Avisa a l'usuari X d'aquest esdeveniment", i el Motor decidirà quin canal utilitzar segons el tipus d'usuari i la configuració del tenant.

La infraestructura tecnològica que hem decidit és la següent:

OneSignal: Només per a Notificacions Push (app/web) cap als nostres usuaris. L'SDK de OneSignal gestionarà els tokens, així que nosaltres només farem servir el nostre user_id intern per referir-nos a ells.

Twilio (BYO - Bring Your Own): Per a SMS i WhatsApp cap a clients externs. Les claus d'API de Twilio pertanyen a cada tenant i es guarden a la nostra base de dades.

Resend: Per a correus electrònics transaccionals (pressupostos, factures, alertes crítiques). Aquest cost l'assumeix el nostre SaaS a nivell global.

Gestió d'Errors: Connectat amb el nostre tenant_operation_logs (Historial d'Operacions).

Genera un pla d'arquitectura i implementació detallat, dividit en les següents fases:

1. Esquema de Base de Dades (PostgreSQL)
Dissenya l'estructura per emmagatzemar de forma segura les credencials BYO de Twilio (SID, Token, Número Remitent) a nivell de Tenant.

Dissenya com guardarem les preferències de notificació a nivell d'Usuari o Contacte (ex: si un client prefereix rebre SMS o Email).

2. Disseny del Servei "Notification Engine" (Patró Facade)
Dissenya una classe o servei unificat (ex: NotificationService.send()) que rebi un tenantId, un recipientId (o dades del destinatari), un eventType (ex: 'INVOICE_GENERATED') i un payload.

Escriu la lògica d'enrutament (Routing Logic): Com decideix el sistema si el missatge va via OneSignal (empleat intern), Twilio (client extern amb configuració BYO) o Resend (fallback o requeriment legal).

3. Gestió d'Errors i Registre a l'Historial d'Operacions
Aplica la nostra regla d'errors de negoci: Si una notificació de Twilio falla perquè les credencials BYO del tenant han caducat o no tenen saldo, el sistema NO ha de trencar el fil d'execució principal.

En lloc d'això, ha de capturar l'error i guardar-lo a la taula tenant_operation_logs indicant que l'SMS per a la intervenció X no s'ha pogut enviar, permetent a l'administrador del tenant veure-ho a la seva interfície.

Si us plau, retorna el pla amb codi TypeScript funcional:

L'esquema SQL/Prisma per a les configuracions.

El pseudocodi o implementació base del NotificationService mostrant el bloqueig try/catch, la decisió d'enrutament cap a OneSignal/Twilio/Resend, i la injecció de l'error al log d'operacions.