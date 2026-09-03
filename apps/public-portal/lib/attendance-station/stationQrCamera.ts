type BarcodeDetectorLike = {
  detect: (source: ImageBitmapSource) => Promise<Array<{ rawValue?: string }>>;
};

declare global {
  interface Window {
    BarcodeDetector?: new (options?: { formats?: string[] }) => BarcodeDetectorLike;
  }
}

export function isNativeQrDetectorSupported(): boolean {
  return typeof window !== "undefined" && typeof window.BarcodeDetector === "function";
}

function buildConstraintAttempts(): MediaStreamConstraints[] {
  return [
    {
      audio: false,
      video: {
        width: { ideal: 1280, min: 640 },
        height: { ideal: 720, min: 480 },
        frameRate: { ideal: 24, max: 30 },
        focusMode: "continuous",
      } as MediaTrackConstraints & { focusMode?: string },
    },
    {
      audio: false,
      video: {
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
    },
    { audio: false, video: true },
  ];
}

export async function openStationCameraStream(): Promise<MediaStream> {
  if (typeof navigator === "undefined" || !navigator.mediaDevices?.getUserMedia) {
    throw new Error("camera_unavailable");
  }

  let lastError: unknown = new Error("camera_unavailable");

  for (const constraints of buildConstraintAttempts()) {
    try {
      const stream = await navigator.mediaDevices.getUserMedia(constraints);
      await enhanceCameraTrack(stream.getVideoTracks()[0]);
      return stream;
    } catch (error) {
      lastError = error;
      if (error instanceof DOMException && error.name === "OverconstrainedError") {
        continue;
      }
      throw error;
    }
  }

  throw lastError;
}

async function enhanceCameraTrack(track: MediaStreamTrack | undefined): Promise<void> {
  if (!track?.applyConstraints) return;

  const attempts: MediaTrackConstraints[] = [
    { focusMode: "continuous" } as MediaTrackConstraints & { focusMode?: string },
    { width: { ideal: 1280 }, height: { ideal: 720 } },
  ];

  for (const constraints of attempts) {
    try {
      await track.applyConstraints(constraints);
      return;
    } catch {
      // Ignore unsupported constraints on this camera/driver.
    }
  }
}

export function attachStreamToVideo(video: HTMLVideoElement, stream: MediaStream): Promise<void> {
  video.srcObject = stream;
  video.muted = true;
  video.playsInline = true;

  return new Promise((resolve, reject) => {
    const onReady = () => {
      cleanup();
      void video
        .play()
        .then(() => resolve())
        .catch(reject);
    };

    const onError = () => {
      cleanup();
      reject(new Error("could not start video source"));
    };

    const cleanup = () => {
      video.removeEventListener("loadedmetadata", onReady);
      video.removeEventListener("error", onError);
    };

    if (video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
      onReady();
      return;
    }

    video.addEventListener("loadedmetadata", onReady, { once: true });
    video.addEventListener("error", onError, { once: true });
  });
}

export function stopMediaStream(stream: MediaStream | null | undefined): void {
  stream?.getTracks().forEach((track) => track.stop());
}

export function startNativeQrDetector(
  video: HTMLVideoElement,
  onDetect: (value: string) => void,
  isActive: () => boolean,
): () => void {
  if (!window.BarcodeDetector) {
    return () => undefined;
  }

  const detector = new window.BarcodeDetector({ formats: ["qr_code"] });
  let frameId = 0;
  let busy = false;

  const tick = () => {
    if (!isActive()) return;

    frameId = window.requestAnimationFrame(() => {
      void (async () => {
        if (!isActive() || busy || video.readyState < HTMLMediaElement.HAVE_ENOUGH_DATA) {
          tick();
          return;
        }

        busy = true;
        try {
          const codes = await detector.detect(video);
          const value = codes[0]?.rawValue?.trim();
          if (value) onDetect(value);
        } catch {
          // Ignore transient detection errors.
        } finally {
          busy = false;
          tick();
        }
      })();
    });
  };

  tick();

  return () => {
    window.cancelAnimationFrame(frameId);
  };
}

export function isQrNotFoundError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  return "name" in err && (err as { name?: string }).name === "NotFoundException";
}

export function scanErrorMessage(err: unknown): string {
  if (err instanceof Error && err.message) return err.message;
  if (typeof err === "object" && err !== null && "message" in err) {
    const message = (err as { message?: unknown }).message;
    if (typeof message === "string" && message.trim()) return message;
  }
  return "";
}
