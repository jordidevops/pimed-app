"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import QRCode from "qrcode";
import { useTranslation } from "react-i18next";
import { issuePortalQrIdentityToken } from "../api/portalApi";

const REFRESH_BUFFER_MS = 15_000;

export function PortalIdentityQrCard() {
  const { t } = useTranslation("portal");
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [expiresAt, setExpiresAt] = useState<Date | null>(null);
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refreshToken = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const issued = await issuePortalQrIdentityToken();
      const canvas = canvasRef.current;
      if (canvas) {
        await QRCode.toCanvas(canvas, issued.token, {
          width: 220,
          margin: 2,
          errorCorrectionLevel: "M",
        });
      }
      setExpiresAt(new Date(issued.expires_at));
    } catch (err) {
      setError(err instanceof Error ? err.message : "qr_token_failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshToken();
  }, [refreshToken]);

  useEffect(() => {
    if (!expiresAt) return;

    const tick = () => {
      const ms = expiresAt.getTime() - Date.now();
      setSecondsLeft(Math.max(0, Math.ceil(ms / 1000)));
      if (ms <= REFRESH_BUFFER_MS) {
        void refreshToken();
      }
    };

    tick();
    const id = window.setInterval(tick, 1000);
    return () => window.clearInterval(id);
  }, [expiresAt, refreshToken]);

  return (
    <section className="rounded-2xl border bg-card p-4 shadow-sm">
      <div className="flex flex-col items-center gap-3 text-center">
        <div>
          <h2 className="text-base font-semibold">
            {t("employee_portal.station_qr.card_title", "QR per estació")}
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              "employee_portal.station_qr.card_hint",
              "Mostra aquest codi al lector de la tablet per identificar-te abans de fitxar.",
            )}
          </p>
        </div>

        <div className="rounded-xl border bg-white p-3">
          <canvas
            ref={canvasRef}
            aria-label={t("employee_portal.station_qr.aria_label", "Codi QR d'identitat")}
            className="block"
          />
        </div>

        {loading ? (
          <p className="text-xs text-muted-foreground">
            {t("employee_portal.station_qr.generating", "Generant codi…")}
          </p>
        ) : secondsLeft != null ? (
          <p className="text-xs text-muted-foreground">
            {t("employee_portal.station_qr.expires_in", "Caduca en {{time}}", {
              time: `${Math.floor(secondsLeft / 60)}:${String(secondsLeft % 60).padStart(2, "0")}`,
            })}
          </p>
        ) : null}

        {error ? <p className="text-sm text-destructive">{error}</p> : null}

        <button
          type="button"
          onClick={() => void refreshToken()}
          disabled={loading}
          className="text-sm text-primary underline disabled:opacity-50"
        >
          {t("employee_portal.station_qr.refresh", "Renovar codi")}
        </button>
      </div>
    </section>
  );
}
