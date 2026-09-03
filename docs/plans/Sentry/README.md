# Sentry

**Pla d'implementació:** [`plan.md`](plan.md) (v3.3 — Sprint 1 codi complet; continuació a [Annex A](plan.md#annex-a--estat-complet-i-full-de-treball)) · **Directrius dev:** [`developer-guidelines.md`](developer-guidelines.md)

---

Actua com un Arquitecte de Programari Expert, especialista en fiabilitat, observabilitat i patrons de disseny en entorns SaaS Multi-Tenant.

A la nostra aplicació SaaS (PostgreSQL, entorn Serverless), necessitem implementar una estratègia professional de gestió d'errors. Hem decidit separar estrictament els errors en dues categories: Errors de Sistema (monitoritzats per desenvolupadors) i Errors de Negoci / Operacions (visibles pels administradors del tenant). A més, tenim una taula audit_logs existent que NO s'ha de barrejar amb els logs d'operacions.

Genera un pla d'implementació exhaustiu, pas a pas, estructurat en les següents fases:

1. Capa Agnòstica d'Errors de Sistema (Patró Adapter / Facade)
Dissenya un servei o mòdul intermedi (ex: LoggerService o SystemErrorTracker) que actuï com a capa agnòstica.

L'objectiu és que la resta del codi mai cridi directament a Sentry.captureException(). Tot el codi ha de cridar a aquesta interfície comuna, de manera que el dia de demà puguem canviar l'adaptador de Sentry a Datadog, New Relic o CloudWatch només tocant un sol fitxer.

Defineix com aquest servei interceptarà automàticament l'entorn (local vs producció) i com injectarà de forma obligatòria el context (especialment el tenant_id i l'user_id) a les traçes de Sentry.

2. Historial d'Operacions / Centre d'Errors de Negoci (UI/UX i BD)
Dissenya l'esquema SQL (PostgreSQL) per a una nova taula (ex: tenant_operation_logs o background_tasks) totalment independent de l'audit_logs.

Defineix quines columnes són necessàries (ex: tipus d'integració, estat, missatge d'error clar, payload resumit) per donar un bon feedback a l'administrador del tenant quan fallen processos asíncrons (Webhooks, sincronització amb ERPs, processament d'IA, importacions).

Proposa un servei al backend (ex: OperationLogService) per escriure i consultar aquests registres de manera estandarditzada.

3. Estratègia de Refactorització del Codi Existent
Crea un pla segur per migrar el codi actual de l'aplicació cap a aquest nou model.

Defineix com hem de substituir els actuals console.error i com gestionar els blocs try/catch (com per exemple els que ja existeixen a funcions com la d'IA) sense trencar la funcionalitat existent.

4. Regles per al Desenvolupament Futur (AI System Prompting)
Redacta una secció clara i estricta de "Directrius de Codi" (Developer Guidelines / AI Rules).

Aquestes regles serviran com a instruccions base perquè, quan una IA o un humà programi noves funcionalitats, sàpiga exactament:

Quan llançar una excepció fatal vs quan retornar un error d'usuari controlat (HTTP 400).

Quan utilitzar el LoggerService (Sentry) vs quan registrar l'error a l'OperationLogService (Taula SQL).

Si us plau, retorna el pla amb exemples pràctics de codi (TypeScript) per a les interfícies/adapters, les consultes SQL per a la creació de les noves taules, i la redacció definitiva de les regles de desenvolupament.

