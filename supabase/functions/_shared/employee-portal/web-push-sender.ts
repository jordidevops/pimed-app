/**
 * Web Push sender for employee portal (VAPID).
 */

import webpush from "web-push";

export interface WebPushSubscription {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

export interface ShiftPushNotification {
  title: string;
  body: string;
  url?: string;
  tag?: string;
}

let vapidConfigured = false;

function ensureVapidConfigured(): boolean {
  if (vapidConfigured) return true;

  const publicKey = Deno.env.get("EMPLOYEE_PORTAL_VAPID_PUBLIC_KEY")?.trim();
  const privateKey = Deno.env.get("EMPLOYEE_PORTAL_VAPID_PRIVATE_KEY")?.trim();
  const subject = Deno.env.get("EMPLOYEE_PORTAL_VAPID_SUBJECT")?.trim() ||
    "mailto:portal@pimed.local";

  if (!publicKey || !privateKey) return false;

  webpush.setVapidDetails(subject, publicKey, privateKey);
  vapidConfigured = true;
  return true;
}

export function isWebPushConfigured(): boolean {
  return Boolean(
    Deno.env.get("EMPLOYEE_PORTAL_VAPID_PUBLIC_KEY")?.trim() &&
      Deno.env.get("EMPLOYEE_PORTAL_VAPID_PRIVATE_KEY")?.trim(),
  );
}

export async function sendWebPushNotification(
  subscription: WebPushSubscription,
  notification: ShiftPushNotification,
): Promise<{ ok: true } | { ok: false; statusCode?: number; gone: boolean }> {
  if (!ensureVapidConfigured()) {
    throw new Error("web_push_not_configured");
  }

  const payload = JSON.stringify({
    title: notification.title,
    body: notification.body,
    url: notification.url ?? "/portal/shifts",
    tag: notification.tag,
  });

  try {
    await webpush.sendNotification(
      {
        endpoint: subscription.endpoint,
        keys: subscription.keys,
      },
      payload,
    );
    return { ok: true };
  } catch (err) {
    const statusCode = (err as { statusCode?: number }).statusCode;
    const gone = statusCode === 404 || statusCode === 410;
    return { ok: false, statusCode, gone };
  }
}
