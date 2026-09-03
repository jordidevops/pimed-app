import type { NotificationSendInput, RenderedNotification, RoutingContext } from "./types.ts";

const EVENT_TITLES: Record<string, Record<string, string>> = {
  TASK_ASSIGNED: {
    ca: "Tasca assignada",
    es: "Tarea asignada",
    en: "Task assigned",
  },
  MENTION_CREATED: {
    ca: "Nova menció",
    es: "Nueva mención",
    en: "New mention",
  },
  INVOICE_GENERATED: {
    ca: "Factura generada",
    es: "Factura generada",
    en: "Invoice generated",
  },
  QUOTE_SENT: {
    ca: "Pressupost enviat",
    es: "Presupuesto enviado",
    en: "Quote sent",
  },
  INTERVENTION_DISPATCHED: {
    ca: "Intervenció assignada",
    es: "Intervención asignada",
    en: "Intervention dispatched",
  },
  SIGNING_REMINDER: {
    ca: "Recordatori de signatura",
    es: "Recordatorio de firma",
    en: "Signing reminder",
  },
  DLQ_ERROR: {
    ca: "Error crític al sistema",
    es: "Error crítico en el sistema",
    en: "Critical system error",
  },
  LEAD_RECEIVED: {
    ca: "Nou lead",
    es: "Nuevo lead",
    en: "New lead",
  },
  NOTIFICATION_TEST: {
    ca: "Notificació de prova",
    es: "Notificación de prueba",
    en: "Test notification",
  },
  ENTITY_TASK_DUE: {
    ca: "Tasca propera a vèncer",
    es: "Tarea próxima a vencer",
    en: "Task due soon",
  },
  ENTITY_TASK_OVERDUE: {
    ca: "Tasca vençuda",
    es: "Tarea vencida",
    en: "Overdue task",
  },
  ENTITY_TIMELINE_ACTIVITY: {
    ca: "Nova activitat",
    es: "Nueva actividad",
    en: "New activity",
  },
  ENTITY_RISK_UNREAD_MENTION: {
    ca: "Menció sense llegir",
    es: "Mención sin leer",
    en: "Unread mention",
  },
  ENTITY_RISK_STATUS_CHURN: {
    ca: "Alta rotació interna",
    es: "Alta rotación interna",
    en: "High internal churn",
  },
  ENTITY_RISK_STALE_THREAD: {
    ca: "Comentari sense resposta",
    es: "Comentario sin respuesta",
    en: "Unanswered comment",
  },
};

function humanizeMentionTokens(content: string): string {
  return content.replace(/\[\[@([0-9a-f-]{36})\|([^\]]+)\]\]/gi, "@$2");
}

function resolveDeepLink(
  template: string | undefined,
  input: NotificationSendInput,
): string | undefined {
  if (
    input.eventType === "MENTION_CREATED"
    || input.eventType === "ENTITY_TASK_DUE"
    || input.eventType === "ENTITY_TASK_OVERDUE"
    || input.eventType === "ENTITY_TIMELINE_ACTIVITY"
    || input.eventType === "ENTITY_RISK_UNREAD_MENTION"
    || input.eventType === "ENTITY_RISK_STALE_THREAD"
  ) {
    const payloadLink = input.payload.deep_link;
    if (typeof payloadLink === "string" && payloadLink.length > 0) {
      return payloadLink;
    }
  }

  if (!template) return undefined;

  const entityId = input.entityId ?? String(input.payload.entity_id ?? "");
  const projectId = String(input.payload.project_id ?? "");
  const commentId = String(input.payload.comment_id ?? "");

  return template
    .replaceAll("{entity_id}", entityId)
    .replaceAll("{project_id}", projectId)
    .replaceAll("{tenant_id}", input.tenantId)
    .replaceAll("{comment_id}", commentId);
}

function resolveBody(
  input: NotificationSendInput,
  locale: string,
  fallbackTitle: string,
): { body: string; bodyI18n: Record<string, string> } {
  const taskTitle = typeof input.payload.title === "string"
    ? input.payload.title.trim()
    : "";

  if (input.eventType === "TASK_ASSIGNED" && taskTitle) {
    const bodyI18n: Record<string, string> = {
      ca: `T'han assignat la tasca «${taskTitle}»`,
      es: `Te han asignado la tarea «${taskTitle}»`,
      en: `You have been assigned the task «${taskTitle}»`,
    };
    return {
      body: bodyI18n[locale] ?? bodyI18n.ca,
      bodyI18n,
    };
  }

  if (input.eventType === "LEAD_RECEIVED") {
    const siteName = typeof input.payload.site_name === "string"
      ? input.payload.site_name
      : "Portal públic";
    const bodyI18n: Record<string, string> = {
      ca: `Nou lead a ${siteName}`,
      es: `Nuevo lead en ${siteName}`,
      en: `New lead on ${siteName}`,
    };
    return {
      body: bodyI18n[locale] ?? bodyI18n.ca,
      bodyI18n,
    };
  }

  if (input.eventType === "NOTIFICATION_TEST") {
    const summary = typeof input.payload.summary === "string"
      ? input.payload.summary
      : "Notificació de prova";
    return {
      body: summary,
      bodyI18n: { ca: summary, es: summary, en: summary },
    };
  }

  if (
    input.eventType === "ENTITY_TASK_DUE"
    || input.eventType === "ENTITY_TASK_OVERDUE"
  ) {
    const rawPreview = typeof input.payload.content_preview === "string"
      ? humanizeMentionTokens(input.payload.content_preview.trim().slice(0, 160))
      : "";
    const entityLabel = typeof input.payload.entity_label === "string"
      ? input.payload.entity_label.trim()
      : "";
    const dueDate = typeof input.payload.due_date === "string"
      ? new Date(input.payload.due_date).toLocaleDateString(
        locale === "en" ? "en-GB" : locale === "es" ? "es-ES" : "ca-ES",
      )
      : "";

    if (input.eventType === "ENTITY_TASK_DUE") {
      const bodyI18n: Record<string, string> = rawPreview
        ? {
          ca: `La tasca «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} venç avui${dueDate ? ` (${dueDate})` : ""}`,
          es: `La tarea «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} vence hoy${dueDate ? ` (${dueDate})` : ""}`,
          en: `Task «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} is due today${dueDate ? ` (${dueDate})` : ""}`,
        }
        : {
          ca: `Tens una tasca que venç avui${entityLabel ? ` a ${entityLabel}` : ""}`,
          es: `Tienes una tarea que vence hoy${entityLabel ? ` en ${entityLabel}` : ""}`,
          en: `You have a task due today${entityLabel ? ` on ${entityLabel}` : ""}`,
        };
      return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
    }

    const bodyI18n: Record<string, string> = rawPreview
      ? {
        ca: `La tasca «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} porta més de 7 dies vençuda`,
        es: `La tarea «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} lleva más de 7 días vencida`,
        en: `Task «${rawPreview}»${entityLabel ? ` (${entityLabel})` : ""} has been overdue for more than 7 days`,
      }
      : {
        ca: `Hi ha una tasca vençuda fa més de 7 dies${entityLabel ? ` a ${entityLabel}` : ""}`,
        es: `Hay una tarea vencida hace más de 7 días${entityLabel ? ` en ${entityLabel}` : ""}`,
        en: `There is a task overdue for more than 7 days${entityLabel ? ` on ${entityLabel}` : ""}`,
      };
    return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
  }

  if (input.eventType === "ENTITY_TIMELINE_ACTIVITY") {
    const kind = typeof input.payload.activity_kind === "string"
      ? input.payload.activity_kind
      : "comment";
    const authorName = typeof input.payload.author_name === "string"
      ? input.payload.author_name.trim()
      : "";
    const entityLabel = typeof input.payload.entity_label === "string"
      ? input.payload.entity_label.trim()
      : "";
    const rawPreview = typeof input.payload.content_preview === "string"
      ? humanizeMentionTokens(input.payload.content_preview.trim().slice(0, 160))
      : "";
    const action = typeof input.payload.action === "string"
      ? input.payload.action.trim()
      : "";

    if (kind === "audit") {
      const bodyI18n: Record<string, string> = {
        ca: `${authorName || "Algú"} ha registrat activitat${entityLabel ? ` a ${entityLabel}` : ""}${action ? ` (${action})` : ""}`,
        es: `${authorName || "Alguien"} ha registrado actividad${entityLabel ? ` en ${entityLabel}` : ""}${action ? ` (${action})` : ""}`,
        en: `${authorName || "Someone"} logged activity${entityLabel ? ` on ${entityLabel}` : ""}${action ? ` (${action})` : ""}`,
      };
      return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
    }

    const bodyI18n: Record<string, string> = rawPreview
      ? {
        ca: `${authorName || "Algú"} ha publicat a${entityLabel ? ` ${entityLabel}` : " l'entitat"}: «${rawPreview}»`,
        es: `${authorName || "Alguien"} ha publicado en${entityLabel ? ` ${entityLabel}` : " la entidad"}: «${rawPreview}»`,
        en: `${authorName || "Someone"} posted on${entityLabel ? ` ${entityLabel}` : " the entity"}: «${rawPreview}»`,
      }
      : {
        ca: `Nova activitat${entityLabel ? ` a ${entityLabel}` : ""}`,
        es: `Nueva actividad${entityLabel ? ` en ${entityLabel}` : ""}`,
        en: `New activity${entityLabel ? ` on ${entityLabel}` : ""}`,
      };
    return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
  }

  if (input.eventType === "MENTION_CREATED") {
    const digestCount = typeof input.payload.digest_count === "number"
      ? input.payload.digest_count
      : Number(input.payload.digest_count ?? 0);
    const entityLabel = typeof input.payload.entity_label === "string"
      ? input.payload.entity_label.trim()
      : "";

    if (digestCount > 1) {
      const bodyI18n: Record<string, string> = entityLabel
        ? {
          ca: `${digestCount} mencions noves a ${entityLabel}`,
          es: `${digestCount} menciones nuevas en ${entityLabel}`,
          en: `${digestCount} new mentions on ${entityLabel}`,
        }
        : {
          ca: `${digestCount} mencions noves`,
          es: `${digestCount} menciones nuevas`,
          en: `${digestCount} new mentions`,
        };
      return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
    }

    const rawPreview = typeof input.payload.content_preview === "string"
      ? input.payload.content_preview.trim().slice(0, 160)
      : "";
    const preview = humanizeMentionTokens(rawPreview);
    const authorName = typeof input.payload.author_name === "string"
      ? input.payload.author_name.trim()
      : "";
    const isReply = input.payload.is_reply === true;

    if (isReply) {
      const bodyI18n: Record<string, string> = preview
        ? {
          ca: `${authorName || "Algú"} ha respost al teu comentari: «${preview}»`,
          es: `${authorName || "Alguien"} ha respondido a tu comentario: «${preview}»`,
          en: `${authorName || "Someone"} replied to your comment: «${preview}»`,
        }
        : {
          ca: `${authorName || "Algú"} ha respost al teu comentari`,
          es: `${authorName || "Alguien"} ha respondido a tu comentario`,
          en: `${authorName || "Someone"} replied to your comment`,
        };
      return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
    }

    const bodyI18n: Record<string, string> = preview
      ? {
        ca: `${authorName || "Algú"} t'ha mencionat: «${preview}»`,
        es: `${authorName || "Alguien"} te ha mencionado: «${preview}»`,
        en: `${authorName || "Someone"} mentioned you: «${preview}»`,
      }
      : {
        ca: `${authorName || "Algú"} t'ha mencionat en un comentari`,
        es: `${authorName || "Alguien"} te ha mencionado en un comentario`,
        en: `${authorName || "Someone"} mentioned you in a comment`,
      };
    return { body: bodyI18n[locale] ?? bodyI18n.ca, bodyI18n };
  }

  const summary = typeof input.payload.summary === "string"
    ? input.payload.summary
    : typeof input.payload.message === "string"
    ? input.payload.message
    : fallbackTitle;

  return {
    body: summary,
    bodyI18n: { ca: summary, es: summary, en: summary },
  };
}

export function renderNotification(
  input: NotificationSendInput,
  routingCtx: RoutingContext,
  locale: string,
): RenderedNotification {
  const titles = EVENT_TITLES[input.eventType] ?? {
    ca: input.eventType,
    es: input.eventType,
    en: input.eventType,
  };

  const digestCount = typeof input.payload.digest_count === "number"
    ? input.payload.digest_count
    : Number(input.payload.digest_count ?? 0);
  const mentionDigestTitle = input.eventType === "MENTION_CREATED" && digestCount > 1
    ? {
      ca: "Noves mencions",
      es: "Nuevas menciones",
      en: "New mentions",
    }
    : null;

  const title = mentionDigestTitle
    ? (mentionDigestTitle[locale] ?? mentionDigestTitle.ca)
    : (titles[locale] ?? titles.ca ?? input.eventType);
  const { body, bodyI18n } = resolveBody(input, locale, title);
  const deepLink = resolveDeepLink(routingCtx.eventMeta?.deepLinkTemplate, input);

  return {
    title,
    body,
    bodyHtml: `<p>${escapeHtml(body)}</p>`,
    smsBody: body.slice(0, 320),
    deepLink,
    titleI18n: mentionDigestTitle ?? titles,
    bodyI18n,
  };
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
