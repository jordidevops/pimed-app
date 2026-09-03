# QUESTIONS
---

## Vegeu tambe

- [Guia de cues (PGMQ)](queues.md)
- [Arquitectura async de product design](product-design/09-async-infrastructure.md)

## 1. Per què `project_events` no surt als docs

Perquè no és una cua de la **infraestructura async central** — és una cua **d'un mòdul de negoci específic** (20260502000001_departments_projects_tasks.sql). El patró és:

- **Infra async** (`20260503000002`) → crea les taules de suport, el `QueueRunner`, les RPCs genèriques
- **Mòduls de negoci** → creen les seves pròpies cues amb `pgmq.create('nom_cua')` i envien missatges des de les seves RPCs

`project_events` és equivalent a `reminders_queue` (mòdul de calendari), `trash_deletion_queue` (mòdul DMS) o `email_send_queue` (mòdul email). Cada mòdul defineix les seves cues. La documentació de `09-async-infrastructure.md` nomes va recollir les tres cues que ja tenien worker, i `project_events` va quedar fora perquè **encara no té worker** (`process-project-events/` no existeix a functions).

---

## 2. Què aporta la infraestructura async — més enllà d'omplir cues

El `QueueRunner` és el que fa la feina real. Resumit del codi que acabes de veure:

```
missatge entra a pgmq → QueueRunner llegeix batch → per cada missatge:
  1. Valida tenant_id        → aïllament multi-tenant garantit
  2. Dedup check             → idempotency_key a data.processed_messages
  3. Resol handler per task  → registre de handlers per nom
  4. Executa handler
       └─ Èxit → dedup record + archive
       └─ Error < maxAttempts → retry amb backoff exponencial
       └─ Error >= maxAttempts → DLQ + notificació critical als owners
  5. Audit del batch sencer  → data.audit_logs (fire-and-forget)
```

**El que guanyes concretament:**

| Problema real | Solució integrada |
|---|---|
| PGMQ entrega "at-least-once" (pot repetir) | Dedup via `data.processed_messages` → el 2n intent s'ignora silenciosament |
| API externa cau puntualment | Retry automàtic amb backoff (60s → 120s → 240s → DLQ) sense cap codi extra al handler |
| Handler falla 3 cops | Missatge arxivat a `data.dlq_messages`, owners reben notificació `severity='critical'` a la inbox |
| "Vaig llançar l'ordre però no sé si va fer res" | Cada batch auditat, cada DLQ auditat, cada tasca a `data.async_tasks` si cal progrés visible |
| Race condition INSERT + missatge a cua | Tot dins la mateixa transacció PostgreSQL: si l'INSERT falla, el missatge mai arriba a la cua |

**El handler en si és mínim** — no ha de saber res de retry, dedup ni DLQ:
```typescript
handlers: {
  enviar_notificacio: async (payload, ctx) => {
    await ctx.db.from('...').insert({...})
    return { success: true }  // ← tot el que has d'escriure
  }
}
```

---

## 3. Cal una Edge Function + un cron per cada cua?

**Sí, per disseny.** Cada cua necessita:

- **1 Edge Function worker** (`process-X-queue/index.ts`) — llegeix el batch i executa handlers
- **1 `cron.schedule`** a la migració SQL — crida la funció per HTTP cada N minuts

Però el cost real és mínim: pg_cron fa una crida HTTP cada N minuts, i si la cua és buida el `QueueRunner` retorna en mil·lisegons (`summary.total = 0`). No hi ha polling actiu ni consum de recursos.

**Freqüència recomanada per tipus de tasca:**
- Email, recordatoris urgents → cada 1-2 min
- Esborrats diferits → cada 5 min
- Exportacions, integracions pesades → cada 5-10 min

**`project_events` té cua però NO té worker** — és un deute tècnic. Els missatges s'acumulen a pgmq sense processador. Si vols tancar el loop, caldria crear `supabase/functions/process-project-events/index.ts` i el `cron.schedule` corresponent.