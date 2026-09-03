Actúa como un Senior Supabase/PostgreSQL Engineer y Arquitecto Backend. Tu objetivo es implementar la V1 de la infraestructura y el backend para un SaaS multi-tenant, y multi-site, basándote en una arquitectura simple, pragmática y robusta que utiliza PostgreSQL, Row Level Security (RLS) y PGMQ para procesamiento asíncrono.

### 🧠 CONTEXTO Y PRINCIPIOS DE DISEÑO
Se requiere un sistema altamente transaccional y desacoplado, sin caer en *overengineering*.
* **Simplicidad > Abstracción:** Nada de motores de reglas o automatizaciones complejas.
* **Código > Base de datos:** La lógica de negocio reside en el código, minimizando el uso de *triggers* complejos.
* **Audit Log, no Event-Driven puro:** La tabla de eventos es estrictamente un registro histórico y de debug, NUNCA un orquestador para disparar lógica.
* **Preparado para escalar:** El procesamiento asíncrono se implementará temporalmente con Supabase Edge Functions (invocadas periódicamente), pero el código de procesamiento debe ser agnóstico y estar estructurado de forma que pueda migrarse a un *worker* externo en Node.js sin cambiar el modelo de datos ni la lógica de negocio.

### ❌ RESTRICCIONES ESTRICTAS (ANTI-PATRONES PROHIBIDOS)
* **PROHIBIDO** implementar sistemas de automatización, *rule engines* o *event-driven orchestration*.
* **PROHIBIDO** usar *triggers* SQL para la lógica de negocio o para encolar tareas. La encolación se hace explícitamente en una transacción desde el backend/cliente.
* **PROHIBIDO** crear abstracciones innecesarias para la gestión de colas.

---

### 🧩 REQUISITOS TÉCNICOS A IMPLEMENTAR

#### 1. Modelo de Datos (SQL DDL)
Debes generar el DDL para las siguientes tablas mínimas. Todas deben soportar `tenant_id` y estar preparadas para crecimiento (índices adecuados en `tenant_id`, `site_id`, `created_at`, `entity_id`):
* `jobs`: Tabla de negocio principal.
* `events`: Audit log estricto (no orquestación).
* `notifications`: Almacena resultados asíncronos para el usuario.
* `processed_messages`: Tabla para garantizar idempotencia.
* `failed_jobs`: Dead Letter Queue (DLQ) para tareas que fallan definitivamente.

#### 2. Seguridad Multi-tenant y RLS (CRÍTICO)
* Implementa políticas RLS completas y estrictas para asegurar que el frontend (usuario autenticado) solo lee e inserta sus propios datos, sin poder modificar logs ni estados internos.
* **Worker Security:** Aunque la Edge Function utilice `service_role` (bypass RLS por defecto), el sistema DEBE aislar las consultas por tenant. Debes incluir explícitamente cómo el worker inyectará el contexto del tenant en la transacción de Postgres antes de ejecutar la lógica de negocio, utilizando:
    ```sql
    SELECT set_config('request.jwt.claims', '{"app_metadata": {"tenant_id": "...", "site_id": "..."} }', true);
    ```

#### 3. Integración con PGMQ
* Uso estándar de `pgmq.send` y lectura de mensajes.
* El payload estándar debe seguir esta estructura:
    ```json
    {
      "task": "send_email",
      "tenant_id": "uuid-del-tenant",
      "site_id": "uuid-del-site",
      "entity_id": "uuid-del-job",
      "idempotency_key": "hash-o-uuid-unico"
    }
    ```

#### 4. Tolerancia a Fallos: Idempotencia, Retries y DLQ
* **Idempotencia (Obligatorio):** Dado que PGMQ garantiza entrega *at-least-once*, el worker debe validar contra la tabla `processed_messages` usando el `msg_id` o `idempotency_key` antes de procesar.
* **Retries y Backoff:** Máximo de 3 intentos. Utiliza *exponential backoff* reprogramando el `visibility timeout` (`vt`) del mensaje en PGMQ si falla.
* **DLQ:** Tras el tercer fallo consecutivo, el mensaje debe extraerse de PGMQ y guardarse en `failed_jobs` con el error detallado.

#### 5. Worker (Edge Function V1)
* Debe actuar haciendo *polling* de PGMQ (ejecución asumida vía cron o trigger, NO loops infinitos en la función).
* Procesamiento por lotes controlado.
* **Desacoplamiento:** La lógica que procesa el mensaje debe estar abstraída en una función pura/reutilizable (ej. `processMessage(message)`), totalmente independiente de los bindings específicos de Deno/Edge Functions, lista para portarse a Node.js.

---

### 📦 ENTREGABLES REQUERIDOS

Debes generar los siguientes 5 artefactos, documentados claramente y listos para producción:

1.  **SQL Completo (Infraestructura y Seguridad):**
    * DDL de todas las tablas requeridas.
    * Índices óptimos y Constraints.
    * Políticas RLS detalladas para cada tabla.
2.  **Transacción Transaccional de Ejemplo (TypeScript/SQL):**
    * Código que demuestre el caso de uso principal (crear un job, registrar en events y hacer enqueue en PGMQ) dentro de una misma transacción (bloque `BEGIN ... COMMIT;` o vía RPC si aplica al cliente, pero asegurando atomicidad).
3.  **Lógica de Procesamiento Desacoplada (TypeScript):**
    * Una clase o módulo independiente de la plataforma que contenga la lógica real (idempotencia, inyección de `set_config` para el RLS, intentos, enrutamiento de la tarea).
4.  **Código del Worker (Supabase Edge Function):**
    * El punto de entrada (*entrypoint*) de la Edge Function.
    * Conexión a Supabase.
    * Lectura de PGMQ por lotes.
    * Invocación a la lógica de procesamiento y manejo de retries/visibility timeout y DLQ.
5.  **Ejemplo End-to-End:**
    * Una breve demostración paso a paso (en código o log conceptual) del flujo completo: inserción -> cola -> procesamiento -> resultado en base de datos.

Antes de empezar, para que pueda revisarla, plantea la solución que propones y la estructura cumpliendo estrictamente estas directrices, aunque tienes libertad para poner en juego tu sentido crítico y proponer mejoras o consideraciones. Todo este sistema debe ser la base para construir sobre ella aplicaciones SaaS más específicas.




> **Rol:** Senior Supabase/PostgreSQL Engineer y Arquitecto Backend.
>
> **Objetivo:** Implementar la V1 de la infraestructura asíncrona para un SaaS Multi-Tenant y **Multi-Site**, utilizando PostgreSQL, RLS y PGMQ.
>
> **Restricciones Estrictas:**
> * Prohibido usar triggers para encolar tareas o implementar *rule engines*. La lógica de encolación es explícita desde el código.
> * La tabla `events` es estrictamente un Audit Log histórico, NO un orquestador event-driven.
>
> **Tareas a realizar:**
>
> **1. Modelo de Datos (SQL DDL):**
> * Crea las tablas `jobs`, `events` (audit log), `notifications`, `processed_messages` (idempotencia) y `failed_jobs` (DLQ).
> * **Contexto Multi-Site:** Todas las tablas deben tener `tenant_id UUID NOT NULL` y `site_id UUID` (opcional, para tareas específicas de un local/marca).
> * Crea índices óptimos (`tenant_id`, `site_id`, `created_at`, `entity_id`).
>
> **2. Seguridad RLS y Contexto del Worker (Crítico):**
> * Aplica RLS para que el usuario autenticado solo vea datos de sus tenants/sites.
> * **Worker Context:** El worker (Edge Function) debe simular el contexto completo aislando la transacción. Debes usar `set_config` inyectando ambos identificadores:
>     `SELECT set_config('request.jwt.claims', '{"app_metadata": {"tenant_id": "...", "site_id": "..."} }', true);`
>
> **3. Integración PGMQ y Tolerancia a Fallos:**
> * El payload JSON de la cola debe incluir `task`, `tenant_id`, `site_id`, `entity_id` y `idempotency_key`.
> * Implementa validación de idempotencia contra `processed_messages` antes de ejecutar la tarea.
> * Implementa *Exponential Backoff* (máximo 3 intentos alterando el `visibility timeout` de PGMQ). Al tercer fallo, el mensaje va a `failed_jobs` (DLQ).
>
> **4. Lógica de Procesamiento Desacoplada (TypeScript):**
> * Crea una función pura `processMessage(message)` totalmente agnóstica a la Edge Function, lista para portarse a un worker de Node.js en el futuro.
> * Dentro de esta función, demuestra cómo se enruta la tarea según el string `task` (ej: `send_report_email`).
>
> **5. Código del Worker (Edge Function V1) y Ejemplo End-to-End:**
> * Crea el entrypoint de la Edge Function haciendo polling controlado a PGMQ.
> * Muestra un ejemplo transaccional (RPC o TS) de cómo el backend inserta la entidad, inserta el `event` (audit) y hace `pgmq.send` en un solo bloque atómico `BEGIN...COMMIT`.

