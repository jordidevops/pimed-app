"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  fetchPortalVapidPublicKey,
  PortalApiError,
  subscribePortalPush,
} from "../api/portalApi";

export type PortalPushOptInContext = "schedule" | "punch";

interface PortalPushOptInProps {
  context?: PortalPushOptInContext;
  className?: string;
}

function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  const output = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i);
  return output;
}

async function hasActiveBrowserPushSubscription(): Promise<boolean> {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return false;
  }

  try {
    const registration = await navigator.serviceWorker.getRegistration("/sw.js");
    if (!registration) return false;
    const subscription = await registration.pushManager.getSubscription();
    return subscription != null;
  } catch {
    return false;
  }
}

export function PortalPushOptIn({ context = "schedule", className = "" }: PortalPushOptInProps) {
  const { t } = useTranslation("portal");
  const [enabled, setEnabled] = useState(false);
  const [loading, setLoading] = useState(true);
  const [subscribing, setSubscribing] = useState(false);
  const [subscribed, setSubscribed] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const titleKey =
    context === "punch" ? "employee_portal.push.punch_title" : "employee_portal.push.title";
  const descriptionKey =
    context === "punch"
      ? "employee_portal.push.punch_description"
      : "employee_portal.push.description";

  useEffect(() => {
    let mounted = true;

    async function load() {
      try {
        const res = await fetchPortalVapidPublicKey();
        if (!mounted) return;
        setEnabled(res.enabled);
        if (res.enabled) {
          const already = await hasActiveBrowserPushSubscription();
          if (mounted) setSubscribed(already);
        }
      } catch {
        if (mounted) setEnabled(false);
      } finally {
        if (mounted) setLoading(false);
      }
    }

    void load();
    return () => {
      mounted = false;
    };
  }, []);

  const handleSubscribe = useCallback(async () => {
    setError(null);
    setSubscribing(true);
    try {
      if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
        setError(t("employee_portal.push.unsupported", "El teu navegador no admet notificacions push"));
        return;
      }

      const { public_key: publicKey } = await fetchPortalVapidPublicKey();
      if (!publicKey) {
        setError(t("employee_portal.push.not_configured", "Notificacions no configurades"));
        return;
      }

      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setError(t("employee_portal.push.denied", "Has denegat les notificacions"));
        return;
      }

      const registration = await navigator.serviceWorker.register("/sw.js");
      await navigator.serviceWorker.ready;

      let subscription = await registration.pushManager.getSubscription();
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(publicKey),
        });
      }

      const json = subscription.toJSON();
      if (!json.endpoint || !json.keys?.p256dh || !json.keys?.auth) {
        throw new Error("invalid_subscription");
      }

      await subscribePortalPush({
        endpoint: json.endpoint,
        keys: { p256dh: json.keys.p256dh, auth: json.keys.auth },
      });
      setSubscribed(true);
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "push_failed";
      setError(code);
    } finally {
      setSubscribing(false);
    }
  }, [t]);

  if (loading || !enabled) return null;

  return (
    <div className={`rounded-lg border bg-muted/30 p-4 ${className}`.trim()}>
      <h3 className="text-sm font-semibold">
        {t(titleKey, context === "punch" ? "Recordatoris de fitxatge" : "Notificacions de torn")}
      </h3>
      <p className="text-muted-foreground mt-1 text-xs">
        {t(
          descriptionKey,
          context === "punch"
            ? "Rep un avís si falta un fitxatge segons el teu horari (entrada, sortida, torn partit)."
            : "Rep un avís quan canviï el teu horari o torn assignat.",
        )}
      </p>
      <p className="text-muted-foreground mt-2 text-xs">
        {t(
          "employee_portal.push.shared_subscription",
          "Una sola activació cobreix canvis de torn i recordatoris de fitxatge.",
        )}
      </p>
      {subscribed ? (
        <p className="mt-3 text-sm text-emerald-700">
          {t("employee_portal.push.subscribed", "Notificacions activades")}
        </p>
      ) : (
        <button
          type="button"
          disabled={subscribing}
          onClick={() => void handleSubscribe()}
          className="mt-3 rounded-md bg-primary px-3 py-2 text-sm font-medium text-primary-foreground disabled:opacity-60"
        >
          {subscribing
            ? t("employee_portal.push.subscribing", "Activant…")
            : t("employee_portal.push.enable", "Activar notificacions")}
        </button>
      )}
      {error && (
        <p className="text-destructive mt-2 text-xs" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
