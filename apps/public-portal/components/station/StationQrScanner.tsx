"use client";

import { formatStationCameraError } from "@/lib/attendance-station/punchUi";
import {
  attachStreamToVideo,
  isNativeQrDetectorSupported,
  isQrNotFoundError,
  openStationCameraStream,
  scanErrorMessage,
  startNativeQrDetector,
  stopMediaStream,
} from "@/lib/attendance-station/stationQrCamera";
import { useEffect, useRef, useState } from "react";

interface StationQrScannerProps {
  onScan: (token: string) => void;
  disabled?: boolean;
  manualAvailable?: boolean;
}

function isCameraInitError(message: string): boolean {
  const normalized = message.toLowerCase();
  return (
    normalized.includes("requested device not found") ||
    normalized.includes("notfounderror") ||
    normalized.includes("device not found") ||
    normalized.includes("notallowederror") ||
    normalized.includes("permission denied") ||
    normalized.includes("notreadableerror") ||
    normalized.includes("could not start video source") ||
    normalized.includes("overconstrainederror") ||
    message === "camera_unavailable"
  );
}

function StationQrScanOverlay({ scanning }: { scanning: boolean }) {
  return (
    <div className="pointer-events-none absolute inset-0">
      <div className="absolute inset-0 flex items-center justify-center">
        <div className="relative aspect-square w-[min(78%,22rem)] overflow-hidden rounded-2xl border-2 border-white/85 shadow-[0_0_0_9999px_rgba(0,0,0,0.58)]">
          <span className="absolute left-0 top-0 h-7 w-7 rounded-tl-2xl border-l-4 border-t-4 border-emerald-400" />
          <span className="absolute right-0 top-0 h-7 w-7 rounded-tr-2xl border-r-4 border-t-4 border-emerald-400" />
          <span className="absolute bottom-0 left-0 h-7 w-7 rounded-bl-2xl border-b-4 border-l-4 border-emerald-400" />
          <span className="absolute bottom-0 right-0 h-7 w-7 rounded-br-2xl border-b-4 border-r-4 border-emerald-400" />
          {scanning ? (
            <span className="absolute inset-x-3 h-0.5 animate-[station-qr-scan_2.1s_ease-in-out_infinite] bg-emerald-300/90 shadow-[0_0_12px_rgba(52,211,153,0.9)]" />
          ) : null}
        </div>
      </div>

      <div className="absolute left-3 top-3 flex items-center gap-2 rounded-full bg-black/70 px-3 py-1.5 text-xs font-medium text-white backdrop-blur-sm">
        <span
          className={`h-2.5 w-2.5 rounded-full ${scanning ? "animate-pulse bg-emerald-400" : "bg-amber-400"}`}
        />
        {scanning ? "Escanejant QR…" : "Preparant càmera…"}
      </div>

      <p className="absolute bottom-3 left-1/2 w-[92%] -translate-x-1/2 text-center text-xs font-medium text-white/90 drop-shadow">
        Centra el QR dins del marc verd
      </p>
    </div>
  );
}

export function StationQrScanner({ onScan, disabled, manualAvailable }: StationQrScannerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const lastTokenRef = useRef<string | null>(null);
  const onScanRef = useRef(onScan);

  const [cameraError, setCameraError] = useState<string | null>(null);
  const [starting, setStarting] = useState(true);
  const [scanning, setScanning] = useState(false);

  onScanRef.current = onScan;

  useEffect(() => {
    if (disabled) return;

    let cancelled = false;
    let stopZxing: (() => void) | null = null;
    let stopNative: (() => void) | null = null;

    const handleDetection = (raw: string) => {
      const text = raw.trim();
      if (!text || text === lastTokenRef.current) return;
      lastTokenRef.current = text;
      onScanRef.current(text);
    };

    void (async () => {
      setStarting(true);
      setScanning(false);
      setCameraError(null);

      try {
        const stream = await openStationCameraStream();
        if (cancelled) {
          stopMediaStream(stream);
          return;
        }

        streamRef.current = stream;

        const video = videoRef.current;
        if (!video) {
          stopMediaStream(stream);
          return;
        }

        await attachStreamToVideo(video, stream);
        if (cancelled) return;

        if (isNativeQrDetectorSupported()) {
          stopNative = startNativeQrDetector(video, handleDetection, () => !cancelled);
        } else {
          const { BrowserQRCodeReader } = await import("@zxing/browser");
          const { DecodeHintType } = await import("@zxing/library");
          const hints = new Map();
          hints.set(DecodeHintType.TRY_HARDER, true);

          const reader = new BrowserQRCodeReader(hints, {
            delayBetweenScanAttempts: 120,
            delayBetweenScanSuccess: 1500,
          });

          const controls = await reader.decodeFromVideoElement(video, (result, err) => {
            if (cancelled) return;
            if (result) {
              handleDetection(result.getText());
              return;
            }
            if (!err || isQrNotFoundError(err)) return;

            const message = scanErrorMessage(err);
            if (message && isCameraInitError(message)) {
              setCameraError(formatStationCameraError(message));
            }
          });

          stopZxing = () => controls.stop();
        }

        if (!cancelled) {
          setStarting(false);
          setScanning(true);
        }
      } catch (err) {
        if (cancelled) return;
        const message = err instanceof Error ? err.message : "camera_unavailable";
        setCameraError(formatStationCameraError(message));
        setStarting(false);
        setScanning(false);
      }
    })();

    return () => {
      cancelled = true;
      stopZxing?.();
      stopNative?.();
      stopMediaStream(streamRef.current);
      streamRef.current = null;
    };
  }, [disabled]);

  if (disabled) {
    return (
      <div className="rounded-2xl border border-dashed p-8 text-center text-sm text-muted-foreground">
        Escàner desactivat
      </div>
    );
  }

  if (cameraError) {
    return (
      <div className="space-y-3">
        <div className="rounded-2xl border border-dashed bg-muted/30 p-8 text-center">
          <p className="text-sm font-medium text-destructive">{cameraError}</p>
          {manualAvailable ? (
            <p className="mt-2 text-sm text-muted-foreground">
              Canvia a &laquo;Selecció manual&raquo; o &laquo;DNI&raquo; per fitxar sense càmera.
            </p>
          ) : null}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="relative overflow-hidden rounded-2xl border bg-black">
        <video ref={videoRef} className="aspect-[4/3] w-full object-cover" muted playsInline />
        <StationQrScanOverlay scanning={scanning} />
      </div>

      <p className="text-sm text-muted-foreground">
        {starting
          ? "Iniciant càmera…"
          : "Mantén el QR estable dins del marc. Ajusta la distància si la imatge surt borrosa."}
      </p>
    </div>
  );
}
