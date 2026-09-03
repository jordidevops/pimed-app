# Contractes d'Events i Workflow Definitions

## 1. Envelope intern d'event

Tot event que entri a `workflow_trigger_queue` ha de seguir aquest contracte.

```jsonc
{
  "event_id": "audit_log_uuid_or_deterministic_key",
  "event_type": "employee.created",
  "tenant_id": "uuid",
  "site_id": "uuid_or_null",
  "entity_type": "employee",
  "entity_id": "uuid",
  "occurred_at": "2026-06-12T10:00:00Z",
  "source_kind": "user | automation | system | external_api",
  "actor_user_id": "uuid_or_null",
  "correlation_id": "uuid_or_string",
  "causation_run_id": "uuid_or_null",
  "causation_step_run_id": "uuid_or_null",
  "depth": 0,
  "payload": {}
}
```

### Camps obligatoris

| Camp | Regla |
|------|-------|
| `event_id` | Estable i idempotent. Per `audit_logs`, usar `audit_logs.id`. |
| `event_type` | Format canònic dot notation: `employee.created`, `document.signed`. |
| `tenant_id` | Sempre obligatori excepte events de plataforma interna. |
| `source_kind` | Permet prevenir bucles i auditar origen. |
| `correlation_id` | Agrupa events d'una mateixa operació d'usuari o workflow. |
| `depth` | Incrementa quan un workflow genera un event que pot disparar workflows. |

## 2. CloudEvents extern

Els webhooks sortints V2 transformaran l'envelope intern a CloudEvents.

```jsonc
{
  "specversion": "1.0",
  "type": "com.app.employee.created",
  "source": "/tenants/{tenant_id}/hr",
  "id": "event_id",
  "time": "occurred_at",
  "datacontenttype": "application/json",
  "subject": "employee/{entity_id}",
  "data": {}
}
```

## 3. Workflow definition

`automation_workflows.steps` ha de ser un array JSONB validat amb Zod. No s'accepten formes lliures.

```jsonc
{
  "schema_version": 1,
  "name": "Onboarding d'empleats",
  "description": "Genera contracte, demana aprovació i envia a signar.",
  "trigger": {
    "event_type": "employee.created",
    "filters": {
      "site_id": null,
      "conditions": []
    },
    "allow_automation_source": false,
    "max_depth": 3
  },
  "steps": [
    {
      "id": "generate_contract",
      "name": "Generar contracte",
      "type": "GENERATE_DOCUMENT",
      "config": {},
      "routing": {
        "on_success": "approve_contract",
        "on_failure": "END_FAIL"
      },
      "retry_policy": {
        "max_attempts": 3,
        "backoff": "exponential",
        "initial_delay_seconds": 30
      },
      "timeout_seconds": 300
    }
  ]
}
```

## 4. Step definition obligatòria

```typescript
export type StepDefinition = {
  id: string
  name: string
  type: StepType
  config: Record<string, unknown>
  routing: {
    on_success: string | null
    on_failure: string | 'END_FAIL' | null
  }
  retry_policy: {
    max_attempts: number
    backoff: 'none' | 'fixed' | 'exponential'
    initial_delay_seconds: number
  }
  timeout_seconds: number | null
}
```

### Regles de validació

- `id` ha de ser únic dins del workflow.
- `routing.on_success` i `routing.on_failure` només poden apuntar a un `step.id` existent o a `null`/`END_FAIL`.
- No pot existir cap cicle. La validació ha de detectar loops abans de guardar.
- El primer step és el primer element de l'array `steps`.
- `retry_policy.max_attempts` ha d'estar entre 1 i 10.
- `timeout_seconds` ha de ser `null` o entre 10 i 86400.
- Cada `type` ha de tenir un schema de `config` propi.

## 5. Step types V1

| Step type | Mode | Descripció |
|-----------|------|------------|
| `SEND_NOTIFICATION` | sync curt | Crea notificació in-app. |
| `SEND_EMAIL` | async delegat | Encua a `email_send_queue`. |
| `CREATE_TASK` | sync curt | Crea tasca interna. |
| `CREATE_CALENDAR_EVENT` | sync curt | Crea event de calendari. |
| `GENERATE_DOCUMENT` | async extern | Genera document/PDF. Pot quedar `WAITING_EXTERNAL`. |
| `SEND_FOR_SIGNING` | async extern | Envia a signatura i espera callback. |
| `HUMAN_APPROVAL` | waiting human | Crea aprovació pendent i pausa el workflow. |
| `CONDITION` | sync curt | Decideix ruta segons expressió limitada. |
| `UPDATE_FIELD` | sync curt | Actualitza camp via RPC/operació controlada. |
| `WAIT` | waiting timer | Pausa fins a una data/hora. |

## 6. Configs mínimes per step type

### SEND_NOTIFICATION

```jsonc
{
  "recipient": {
    "mode": "actor | role | explicit_user | field_path",
    "value": "manager"
  },
  "kind": "automation",
  "severity": "info | success | warning | error",
  "title_template": "Contracte pendent d'aprovació",
  "body_template": "Revisa el contracte de {{ employee.full_name }}"
}
```

### HUMAN_APPROVAL

```jsonc
{
  "assigned_to": {
    "mode": "role | explicit_user | field_path",
    "value": "manager"
  },
  "title_template": "Revisa {{ document.title }}",
  "summary_template": "Aprovació necessària per continuar el workflow.",
  "preview": {
    "document_id_path": "steps.generate_contract.output.document_id",
    "fields": ["employee.full_name", "employee.email", "employee.start_date"]
  },
  "due_in_hours": 48
}
```

### CONDITION

```jsonc
{
  "expression": "employee.department_slug == 'rrhh'",
  "on_true": "step_id_true",
  "on_false": "step_id_false"
}
```

A V1, les expressions han de ser limitades. Evitar SQL lliure. Recomanat: motor d'expressions intern amb comparacions simples sobre paths del context.

## 7. Event taxonomy V1

Els events interns han d'usar dot notation. Es pot mapar des dels noms legacy d'audit action.

| Event canònic | Possible audit action origen |
|---------------|-----------------------------|
| `employee.created` | `EMPLOYEE_CREATED` |
| `employee.updated` | `EMPLOYEE_UPDATED` |
| `document.generated` | `DOCUMENT_GENERATED` |
| `document.signed` | `DOCUMENT_SIGNED` |
| `document.signing_rejected` | `DOCUMENT_SIGNING_REJECTED` |
| `contact.created` | `CONTACT_CREATED` |
| `lead.created` | `LEAD_CREATED` |
| `project.status_changed` | `PROJECT_STATUS_CHANGED` |
| `task.completed` | `TASK_COMPLETED` |
| `work_order.created` | `WORK_ORDER_CREATED` |
| `absence.requested` | `ABSENCE_REQUESTED` |
| `absence.approved` | `ABSENCE_APPROVED` |
| `date_field.reached` | `DATE_FIELD_REACHED` |

## 8. Versioning

- `automation_workflows.schema_version`: versió del format JSONB.
- `automation_workflows.version`: versió editable del workflow del tenant.
- `automation_runs.workflow_version`: versió usada per la run.
- `automation_runs.workflow_snapshot`: còpia immutable de la definició usada.

Cap run en curs ha de llegir steps des de la definició mutable del workflow.
