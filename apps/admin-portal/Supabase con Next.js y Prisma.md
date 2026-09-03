# Una base de datos Postgres varias apps de frontend

Dado que tenemos el Hosting en Vercel podemos aprovechar que son los creadores de Next.js y por tanto su hosting soporta sin problema las funcionalidades de SSR que incorpora.

La app para los clientes (o tenants) la tenemos en React+Vite pero necesitamos una app para gestionar estos tenenants (crearlos, ver consumos, features flags,...), una app backoffice para la startup.

La app de clientes utiliza el cliente de Supabase (@supabase/supabase-js) con seguridad RLS en Postgres para el multitenant. Pero para la app de backoffice debemos poder trabajar sobre toda la base de datos, por tanto proponemos un enfoque distinto, utilizar el ORM Prisma para la app y para conectar con Postgres haciendo un *bypass* al RLS.


Ambas aplicaciones apuntan a la **misma base de datos PostgreSQL**, pero usan "puertas" diferentes:

* **App Clientes (React + Vite):** Entra via api de **PostgREST**. Usa el JWT del usuario y el **RLS** garantiza que la empresa A no vea los datos de la empresa B.
* **App Backoffice (Next + Prisma):** Entra por la puerta directa (TCP/Pooler). Al usar Prisma con la conexión directa (o con `service_role_key` en los casos que sea necesario), el **RLS se ignora**. Esto es ideal porque los administradores de la startup necesitan ver métricas globales de todos los clientes.

El cloud de Supabase ofrece varias formas de conectarse en "Connect to your project. Choose how you want to use Supabase".

La opción "Frameword. Use a client library" es la que utilizamos para la app clientes (React+Vite) con las VITE_SUPABASE_URL y VITE_SUPABASE_PUBLISHABLE_DEFAULT_KEY.

Para el backoffice utilizaremos "ORM. Third-party library" con las DATABASE_URL y DIRECT_URL.

Las primeras son seguras de poner en el código de frontend, las segundas no pero Next.js las utiliza solo en código de servidor. En NextJS una clave en .env se expone en el frontend solo si empieza por NEXT_PUBLIC_.

Los ORM (Prisma en este caso) normalmente se utilizan con este flujo:

Aquí tienes el flujo típico de Prisma de forma breve:

1. **Definir esquema**

   * En `schema.prisma`
   * Modelas tablas, relaciones y campos

2. **Migrar base de datos**

   ```bash
   npx prisma migrate dev
   ```

   * Prisma genera SQL
   * Aplica cambios a la BD
   * Guarda historial de migraciones

3. **Generar cliente y tipos**

   ```bash
   npx prisma generate
   ```

   * Crea `PrismaClient`
   * Genera tipos TypeScript automáticamente

4. **Usar en código**

   * Haces queries desde el cliente
   * Prisma traduce a SQL

---

## Resumen

Es el enfoque schema-first:

```text
schema.prisma → migrate → generate → usar en código
```

Pero en Supabase si seguimos este enfoque podemos chocar con las migraciones hechas en /supabase/migrations.

**No podemos tener dos "dueños" de la estructura de la base de datos.**

* **Si usamos el CLI de Supabase (`supabase db push`) (o el editor en el cloud):** Generamos archivos `.sql`.
* **Si usamos Prisma (`prisma migrate dev`):** Generamos archivos `.sql` dentro de una carpeta `prisma/migrations`.


Como ya tenemos migraciones SQL decidimos que Supabase CLI sea el "dueño" de la estructura y que Prisma actue solo como cliente de esta estructura, es decir, no usaremos *prisma migrate*.

Lo que haremos es sincronizar Prisma con Supabase (Introspection) con 

```bash
npx prisma db pull
```

Con esto conseguimos:

* Escanear tablas, columnas, relaciones y tipos en Supabase.
* Generar el modelo en el archivo `.prisma`.
* **Seguridad:** Detectar si una columna es obligatoria o nula, dándo errores de TypeScript si intentamos insertar datos incompletos en el Backoffice.

Una vez que el esquema refleja la realidad de la base de datos, generamos el motor de consultas, el **cliente Prisma**:
```bash
npx prisma generate
```

Ahora podemos hacer consultas potentes ignorando el RLS:

```typescript
import { PrismaClient } from '@prisma/client'

const prisma = new PrismaClient()

export default async function AdminDashboard() {
  // Obtenemos el conteo de sedes por cada Tenant
  const stats = await prisma.tenants.findMany({
    include: {
      _count: {
        select: { sedes: true }
      }
    }
  })

  return (
    <div>
      <h1>Panel de Control Startup</h1>
      {stats.map(t => (
        <p key={t.id}>{t.name}: {t._count.sedes} proyectos</p>
      ))}
    </div>
  )
}
```

## ¿Necesitamos la Service Role Key de Supabase con Prisma?

No, Prisma utiliza conexión directa por TCP con Postgres utilizando la contraseña de la base de datos.

* **Supabase SDK (`supabase-js`):** Se comunica mediante **HTTP** con una API (PostgREST). Esa API es la que exige una "Key" (Anon o Service Role) para dejarnos pasar.
* **Prisma:** Se comunica mediante el protocolo nativo de PostgreSQL (**TCP**). No habla con ninguna API de Supabase; habla directamente con el motor de la base de datos. Solo necesitamos el **Usuario** y la **Contraseña** de la base de datos.

Necesitaremos la **Service Role Key** si usamos el cliente de Supabase para:
1.  **Gestionar Usuarios:** Crear, borrar o invitar usuarios manualmente (`supabase.auth.admin`).
2.  **Edge Functions:** Llamar a funciones privadas desde el servidor.
3.  **Storage:** Borrar archivos del bucket de forma administrativa.



## Lo que no debemos hacer

Las migraciones con Supabase, nunca debemos hacer

   ```bash
   npx prisma migrate
   ```



## La configuración

La web de Supabase nos dice que debemos configurar Prisma en el archivo prisma/schema.prisma con

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_URL")
}
```

ATENCIÓN: En Prisma 7 las url de conexión van en prisma.config.ts no en schema.prisma. Y parece que debemos usar solo la conexión directa (DIRECT_URL en puerto 5432) no el Transaction Pooler (puerto 6543) porque el driver adapter (@prisma/adapter-pg) ya gestiona el pooling.


```typescript
import 'dotenv/config'
import { defineConfig } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: {
    // En staging/prod: URL del Transaction Pooler de Supabase
    url: process.env.DATABASE_URL ?? '',
  },
})
```

Según la AI al preguntarle sobre DATABASE_URL y DIRECT_URL...

Esta es una de las configuraciones más importantes cuando conectas **Prisma** con **Supabase**, porque responde a una limitación física de las bases de datos: **las conexiones no son infinitas**.

Para que Prisma funcione de forma eficiente en la nube (especialmente en entornos como Vercel o AWS Lambda), necesita dos "carriles" distintos para hablar con Postgres.

---

### 1. `DATABASE_URL` (El carril del tráfico diario)
Esta URL apunta al **Connection Pooler** (normalmente a través de **PgBouncer** o el nuevo **Supabase Auth/Supavisor**). 

* **Puerto típico:** 6543.
* **Para qué sirve:** Se usa para el **tiempo de ejecución** (runtime) de tu aplicación. Cada vez que tu Backoffice hace un `prisma.user.findMany()`, usa esta URL.
* **Por qué existe:** Las funciones Serverless (como las de Next.js) se encienden y apagan constantemente. Si cada función abriera una conexión directa a Postgres, la base de datos se quedaría sin "slots" de conexión en segundos y daría error. El Pooler mantiene un grupo de conexiones abiertas y las reparte entre las miles de peticiones de tu app.

> **Configuración en Prisma:** En tu `schema.prisma`, esta URL se asigna al campo `url`.

---

### 2. `DIRECT_URL` (El carril de mantenimiento)
Esta URL apunta **directamente** al motor de la base de datos PostgreSQL, saltándose cualquier intermediario.

* **Puerto típico:** 5432.
* **Para qué sirve:** Se usa exclusivamente para operaciones que necesitan un control total del sistema, como las **migraciones** (`prisma migrate`) o la **introspección** (`prisma db pull`).
* **Por qué existe:** Los administradores de conexiones (Poolers) a menudo no permiten comandos complejos de estructura (como crear tablas o índices) o tienen tiempos de espera (timeouts) muy cortos. Prisma necesita una "línea directa" y estable para analizar o modificar el esquema de la base de datos sin interferencias.

> **Configuración en Prisma:** En tu `schema.prisma`, esta URL se asigna al campo `directUrl`.



---

### ¿Cómo se configura en tu código?

En tu archivo `schema.prisma`, debes declarar ambas para que Prisma sepa cuándo usar cada una:

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")   // Usa el puerto 6543 (con pooling)
  directUrl = env("DIRECT_URL")     // Usa el puerto 5432 (directo)
}
```

Y en tu archivo `.env` (o en las variables de entorno de Vercel/Supabase):

```bash
# Ejemplo con Supabase
DATABASE_URL="postgresql://postgres:[PASSWORD]@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?pgbouncer=true"
DIRECT_URL="postgresql://postgres:[PASSWORD]@aws-1-eu-central-1.pooler.supabase.com:5432/postgres"
```

---

### Resumen de diferencias

| Característica | `DATABASE_URL` (Pooling) | `DIRECT_URL` (Directa) |
| :--- | :--- | :--- |
| **Puerto** | 6543 | 5432 |
| **Uso principal** | Consultas CRUD de la App (Next.js/NestJS). | `db pull`, `db push`, `migrate`. |
| **Ventaja** | Escala a miles de usuarios simultáneos. | Permite comandos SQL administrativos complejos. |
| **Riesgo** | No apta para cambios de estructura. | Puede agotar las conexiones si se usa en la App. |




## Qué conseguimos con Prisma (según AI)

### 1. Type Safety Extremo (Autocompletado)
Esta es la ventaja número uno. Al ejecutar `npx prisma db pull`, Prisma lee tu base de datos de Supabase y genera un mapa exacto de TypeScript.
* **Sin Prisma:** Tienes que escribir manualmente las interfaces de tus tablas o confiar en que el generador de tipos de Supabase esté actualizado.
* **Con Prisma:** Si escribes `prisma.users.update({ data: { emal: ... } })` (con error de ortografía), **TypeScript te dará un error en rojo** antes de que intentes ejecutarlo. Prisma sabe exactamente qué columnas existen, si aceptan nulos y de qué tipo son.

### 2. Relaciones "Deep" con una sola consulta
En un Backoffice, a menudo necesitas datos de varias tablas relacionadas (ej: "Trae los clientes, sus suscripciones y el historial de pagos").
* **Con Prisma:** Usas el operador `include`. Prisma genera un SQL optimizado (Joins) y te devuelve un objeto JSON perfectamente anidado y tipado.
* **Ventaja:** Te ahorras hacer 3 o 4 peticiones por separado al cliente de Supabase, lo que reduce la latencia y la complejidad de tu código.

```typescript
// Ejemplo de consulta compleja en un solo paso
const data = await prisma.tenant.findUnique({
  where: { id: '123' },
  include: {
    projects: true,
    owner: true,
    billing_history: { take: 5 }
  }
})
```

### 3. Abstracción del SQL Complejo
Prisma actúa como un "traductor inteligente". No necesitas recordar la sintaxis exacta de Postgres para operaciones comunes pero tediosas:
* **Paginación:** Es tan simple como `take: 10, skip: 20`.
* **Filtros avanzados:** `startsWith`, `contains`, `gte` (mayor que), etc., se escriben de forma intuitiva como objetos de JavaScript.
* **Agregaciones:** Sacar el promedio, la suma o el conteo de una tabla de ventas para el dashboard de la startup es una sola línea de código.

### 4. Transacciones Robustas
En el Backoffice podrías necesitar hacer cambios en "cascada". Por ejemplo: *"Cuando un administrador borra un Tenant, también quiero archivar sus proyectos y registrar un log de auditoría"*.
* Prisma permite agrupar estas operaciones en una **Transacción**. Si una falla, ninguna se aplica. Esto garantiza que tu base de datos nunca se quede en un estado "corrupto" o inconsistente.



### 5. Validación de Datos en "Tiempo de Escritura"
Prisma no solo lee, también protege. Si intentas insertar un string en una columna que Supabase definió como `integer`, Prisma lanzará una excepción clara en tu servidor de Next.js antes de enviar la basura a la base de datos. Esto te ahorra ver errores crípticos de PostgreSQL en los logs.

---

### 6. Independencia del "Owner" del Esquema
Al no usar Prisma para migraciones, eliminas el riesgo de **choques de esquema**.
* Puedes cambiar una tabla desde el Dashboard de Supabase tranquilamente.
* Luego corres `npx prisma db pull`.
* Tu Backoffice se actualiza al instante con los nuevos campos.

### Resumen de Beneficios para la Startup

| Beneficio | Impacto en el Backoffice |
| :--- | :--- |
| **Velocidad de Desarrollo** | Creas dashboards y formularios CRUD en la mitad de tiempo. |
| **Menos Bugs** | TypeScript detecta errores de base de datos mientras escribes código. |
| **Rendimiento** | Consultas SQL más eficientes gracias a los `joins` nativos de Prisma. |
| **Mantenibilidad** | El código es mucho más legible que las cadenas de texto SQL o las llamadas anidadas del SDK. |

En definitiva, usas Prisma por la **Experiencia de Desarrollador (DX)**. Dejas que Supabase CLI se encargue de la "ingeniería civil" (la estructura) mientras Prisma se encarga de la "decoración y logística" (los datos).

