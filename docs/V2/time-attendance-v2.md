# Control Horari — Backlog V2

Funcionalitats explícitament excloses de V1 i posposades a V2. El criteri d'exclusió és:
(a) complexitat tècnica elevada sense demanda urgent, (b) dependència d'integracions externes no preparades, o (c) risc d'afectar la data de lliurament del compliment legal.

> **Prerequisit:** totes les fases V1 (docs 14–17) han d'estar en producció i estables.

---

## 1. Identificació per QR i codi de barres a estacions

**Descripció:** Els empleats s'identifiquen a l'estació escanejant un QR o codi de barres generat pel servidor, en comptes de seleccionar-se manualment de la llista.

**Per què V2:** Requereix `api.issue_attendance_identity_token` i `api.resolve_attendance_identity_token` (tokens signats HMAC amb `tenant_id`, `employee_id`, `exp`, `nonce`). En V1 la selecció manual és suficient i elimina la complexitat de gestió de tokens client-side.

**Abast V2:**
- RPC `api.issue_attendance_identity_token(p_method)` — emet token JWT curt (5 min exp)
- RPC `api.resolve_attendance_identity_token(p_token, p_device_public_id)` — valida i retorna employee_id
- UI per generar i mostrar el QR personal a l'app de l'empleat
- Lectura de codi de barres des del lector físic de l'estació

---

## 2. Payroll complet amb nòmina legal

**Descripció:** Càlcul i generació de nòmines legals espanyoles (seguretat social, IRPF, bases de cotització, model TC1/TC2).

**Per què V2:** Requereix coneixement profund del conveni col·lectiu aplicable, categoria professional, antiguitat i normativa fiscal que varien per empresa i sector. V1 genera els resums d'hores aprovats per a importació a software de nòmines extern.

**Abast V2:**
- Model `data.payroll_contracts` — configuració laboral (conveni, categoria, salari base, complements)
- Càlcul IRPF i bases de cotització per empleat i mes
- Generació fitxer TC2 per a TGSS
- Export model 111 (AEAT)
- Integració directa amb A3 RRHH / Sage 200 via API (si disponible)

---

## 3. Sincronització en segon pla garantida (iOS)

**Descripció:** Background sync garantit en dispositius iOS quan l'app está tancada o en background.

**Per què V2:** iOS limita severament el Background Fetch i els Service Workers. En V1, la sincronització s'activa quan l'usuari obre l'app o recupera connexió en primer pla. En V2 cal investigar Push Notifications + background task per activar el sync.

**Abast V2:**
- Service Worker amb Background Sync API (Chrome/Android)
- iOS: Push Notification silenciosa que activa sync en background
- Indicador de "sync pendent des de Xh" a la pantalla de l'empleat

---

## 4. Biometria, NFC i BLE per a estacions

**Descripció:** Identificació d'empleats a estació fixes via empremta digital, NFC (targeta o mòbil) o Bluetooth Low Energy.

**Per què V2:** Requereix hardware específic i integracions de tercers (WebAuthn per biometria, Web NFC API, BLE via Web Bluetooth o app nativa). V1 cobreix els casos d'ús principals amb selecció manual i QR.

**Abast V2:**
- Identificació per empremta (WebAuthn / FIDO2 lligat a `employee_id`)
- Identificació per targeta NFC (codi llegit via Web NFC API)
- Identificació per BLE beacon (empleats amb wearable o targeta BLE)
- Gestió d'enrolament de dispositius biometrics per empleat

---

## 5. Geofencing dur (bloqueig per distància GPS)

**Descripció:** Bloquejar completament el fitxatge si l'empleat és fora del radi GPS permès per la seva location assignada.

**Per què V2:** En V1 el mode `block` és configurable però comporta risc de bloqueig fals (GPS indoor poc fiable, edificis alts, tunels). Cal un període d'observació en mode `warn` per calibrar radis i reduir falsos positius abans d'activar el bloqueig dur.

**Abast V2:**
- Geofencing per polígon GeoJSON (no només radi circular)
- Mode `block` auditat i amb override manager d'emergència
- Dashboard d'anomalies GPS per calibrar radis per location

---

## 6. Realtime dashboard i notificacions push

**Descripció:** Vista en temps real de qui ha fitxat, qui falta, alertes immediates d'anomalies.

**Per què V2:** En V1 el refresc és per polling o manual. Supabase Realtime és útil per UX però no garantia de sync. V2 pot afegir:

**Abast V2:**
- Supabase Realtime subscription a `time_punches` i `time_daily_summaries`
- Dashboard manager en temps real: empleats fitxats vs. esperat
- Push notifications via Web Push (anomalia detectada, aprovació pendent)
- Integració amb `data.communications` per recordatoris outbound (SMS/WhatsApp)

---

## 7. Saldo de vacances i permisos amb reguera anual

**Descripció:** Comptador automàtic de dies de vacances disponibles, consumits i pendents per any, amb gestió de la reguera d'un any a l'altre.

**Per què V2:** Requereix regles de conveni (normalment 22–30 dies hàbils/any), data d'antiguitat, càlcul pro-rata per altes i baixes, i caducitat de dies no consumits. Complexitat legal elevada.

**Abast V2:**
- `data.leave_balances` — saldo per tipus d'absència, any i empleat
- Càlcul automàtic al tancament de l'any (pg_cron)
- Aprovació de sol·licituds bloquejada si no hi ha saldo disponible
- Informe de saldos per empleat i per departament

---

## 8. Integració amb Seguretat Social i AEAT

**Descripció:** Envio electrònic de comunicats a la Tresoreria General (SILTRA/Certific@2) i a l'AEAT (model 111).

**Per què V2:** Requereix certificats digitals, contracte amb un SII/EDI, i coneixement del format Certific@2 (XML específic). Fora de l'abast del compliment del registre horari.

**Abast V2:**
- Integració Certific@2 per comunicats de baixa (IT)
- Export model TC2 per cotitzacions mensuals
- Connexió API AEAT (si l'administració publica una API oficial)

---

## 9. Optimitzador de torns amb IA

**Descripció:** Suggeriment automàtic de planificació de torns basant-se en demanda històrica, cobertura mínima requerida i preferències dels empleats.

**Per què V2:** Requereix dades históriques acumulades de V1 (mínim 3–6 mesos) i un model de predicció. Pot integrar-se amb OpenAI o un model propi entrenat amb dades del sector.

**Abast V2:**
- Anàlisi de patrons de demanda per franja horària i dia de la setmana
- Proposta automàtica de torns optimitzats (minimitzar hores extra, maximitzar cobertura)
- Gestió de preferències de torn dels empleats (`preferred_shifts`, `unavailable_dates`)
- Comparació cost laboral entre planificacions alternatives

---

## 10. App mòbil nativa (iOS/Android)

**Descripció:** Aplicació nativa en lloc de PWA per a una experiència més fluida, notificacions push natives i accés a hardware del dispositiu.

**Per què V2:** La PWA és suficient per al compliment legal V1. Una app nativa aportaria millors capacitats offline, accés directe a GPS/NFC/biometria i notificacions push natives sense limitacions iOS.

**Abast V2:**
- React Native (Expo) amb codebase compartit amb la PWA
- Sincronització en background nativa
- Notificacions push via APNs / FCM
- Biometria nativa (Face ID, Touch ID) com a factor d'autenticació addicional
