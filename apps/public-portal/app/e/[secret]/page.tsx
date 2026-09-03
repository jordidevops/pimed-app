"use client";

import { Suspense, useRef } from "react";
import { useCallback, useEffect, useState } from "react";
import { useParams, useRouter, useSearchParams } from "next/navigation";
import { useTranslation } from "react-i18next";
import { IdentityConfirmGate } from "@/features/employee-portal/components/IdentityConfirmGate";
import { IdentityDocumentGate } from "@/features/employee-portal/components/IdentityDocumentGate";
import { PinGate } from "@/features/employee-portal/components/PinGate";
import { PinSetupGate } from "@/features/employee-portal/components/PinSetupGate";
import {
  confirmPortalIdentity,
  createPortalSession,
  fetchBootstrapState,
  PortalApiError,
  rejectPortalIdentity,
  setupPortalPin,
  verifyPortalIdentity,
  type PortalBootstrapState,
} from "@/features/employee-portal/api/portalApi";
import { normalizePortalSecret } from "@/features/employee-portal/utils/portalSecretUtils";

type BootstrapPhase =
  | "loading"
  | "identity_document"
  | "identity_confirm"
  | "identity_rejected"
  | "identity_not_configured"
  | "pin"
  | "pin_setup"
  | "error";

function phaseFromBootstrapState(state: PortalBootstrapState): BootstrapPhase {
  switch (state) {
    case "requires_identity":
      return "identity_document";
    case "identity_not_configured":
      return "identity_not_configured";
    case "token_invalid":
      return "error";
    case "pin_setup":
      return "pin_setup";
    case "pin":
      return "pin";
    case "ready":
      return "loading";
    default:
      return "error";
  }
}

function EmployeePortalBootstrapInner() {
  const params = useParams<{ secret: string }>();
  const router = useRouter();
  const searchParams = useSearchParams();
  const { t } = useTranslation("portal");
  const [phase, setPhase] = useState<BootstrapPhase>("loading");
  const [errorCode, setErrorCode] = useState<string | null>(null);
  const [retryAfterSeconds, setRetryAfterSeconds] = useState<number | null>(null);
  const [pendingFullName, setPendingFullName] = useState<string | null>(null);
  const secret = normalizePortalSecret(params.secret);
  const bootstrapStartedRef = useRef(false);

  const navigateAfterSession = useCallback(() => {
    const next = searchParams.get("next");
    const year = searchParams.get("year");
    const month = searchParams.get("month");
    if (next === "monthly" && year && month) {
      router.replace(
        `/portal/monthly?year=${encodeURIComponent(year)}&month=${encodeURIComponent(month)}`,
      );
    } else {
      router.replace("/portal/punch");
    }
  }, [router, searchParams]);

  const openSession = useCallback(
    async (pin?: string) => {
      if (!secret) return;
      setErrorCode(null);
      setRetryAfterSeconds(null);

      if (pin && !navigator.onLine) {
        setPhase("pin");
        setErrorCode("offline_pin");
        return;
      }

      try {
        await createPortalSession(secret, pin);
        navigateAfterSession();
      } catch (err) {
        const code = err instanceof PortalApiError ? err.code : "bootstrap_failed";
        const retry =
          err instanceof PortalApiError ? (err.retryAfterSeconds ?? null) : null;

        if (code === "identity_required") {
          setPhase("identity_document");
          return;
        }
        if (code === "pin_setup_required") {
          setPhase("pin_setup");
          return;
        }
        if (code === "pin_required") {
          setPhase("pin");
          return;
        }
        if (code === "pin_invalid" || code === "pin_locked") {
          setPhase("pin");
          setErrorCode(code);
          setRetryAfterSeconds(retry);
          return;
        }
        setPhase("error");
        setErrorCode(code);
      }
    },
    [navigateAfterSession, secret],
  );

  const continueAfterIdentity = useCallback(
    async (next: "pin_setup" | "pin" | "ready") => {
      if (next === "pin_setup") {
        setPhase("pin_setup");
        return;
      }
      if (next === "pin") {
        setPhase("pin");
        return;
      }
      await openSession();
    },
    [openSession],
  );

  const resolveBootstrap = useCallback(async () => {
    if (!secret) return;

    setErrorCode(null);
    setRetryAfterSeconds(null);
    setPendingFullName(null);
    setPhase("loading");

    try {
      const bootstrap = await fetchBootstrapState(secret);
      const nextPhase = phaseFromBootstrapState(bootstrap.state);

      if (bootstrap.identity_locked) {
        setErrorCode("identity_locked");
        setRetryAfterSeconds(bootstrap.retry_after_seconds ?? null);
      }

      if (bootstrap.state === "ready") {
        await openSession();
        return;
      }

      setPhase(nextPhase);
      if (nextPhase === "error") {
        setErrorCode("token_invalid");
      }
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "bootstrap_failed";
      setPhase("error");
      setErrorCode(code);
    }
  }, [openSession, secret]);

  const handleVerifyDocument = useCallback(
    async (documentId: string) => {
      if (!secret) return;
      setErrorCode(null);
      setRetryAfterSeconds(null);

      try {
        const result = await verifyPortalIdentity(secret, documentId);
        setPendingFullName(result.full_name);
        setPhase("identity_confirm");
      } catch (err) {
        const code = err instanceof PortalApiError ? err.code : "identity_verify_failed";
        const retry =
          err instanceof PortalApiError ? (err.retryAfterSeconds ?? null) : null;
        setErrorCode(code);
        setRetryAfterSeconds(retry);
        if (code === "identity_not_configured") {
          setPhase("identity_not_configured");
        }
        throw err;
      }
    },
    [secret],
  );

  const handleConfirmIdentity = useCallback(async () => {
    if (!secret) return;
    setErrorCode(null);

    try {
      const result = await confirmPortalIdentity(secret);
      setPendingFullName(result.full_name);
      await continueAfterIdentity(result.next);
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "bootstrap_failed";
      setErrorCode(code);
      if (code === "identity_challenge_required") {
        setPendingFullName(null);
        setPhase("identity_document");
      }
      throw err;
    }
  }, [continueAfterIdentity, secret]);

  const handleRejectIdentity = useCallback(async () => {
    if (!secret) return;

    try {
      await rejectPortalIdentity(secret);
      setPendingFullName(null);
      setPhase("identity_rejected");
    } catch (err) {
      const code = err instanceof PortalApiError ? err.code : "bootstrap_failed";
      setPhase("error");
      setErrorCode(code);
    }
  }, [secret]);

  const handleSetupPin = useCallback(
    async (pin: string, confirmPin: string) => {
      if (!secret) return;
      setErrorCode(null);
      setRetryAfterSeconds(null);

      try {
        await setupPortalPin(secret, pin, confirmPin);
        navigateAfterSession();
      } catch (err) {
        const code = err instanceof PortalApiError ? err.code : "pin_setup_failed";
        setErrorCode(code);
        setRetryAfterSeconds(
          err instanceof PortalApiError ? (err.retryAfterSeconds ?? null) : null,
        );
        if (code === "identity_required") {
          setPhase("identity_document");
          return;
        }
        if (code === "pin_already_set" || code === "pin_setup_not_required") {
          void openSession();
          return;
        }
        throw err;
      }
    },
    [navigateAfterSession, openSession, secret],
  );

  useEffect(() => {
    if (!secret || bootstrapStartedRef.current) return;
    bootstrapStartedRef.current = true;
    void resolveBootstrap();
  }, [resolveBootstrap, secret]);

  if (phase === "identity_document") {
    return (
      <IdentityDocumentGate
        onSubmit={handleVerifyDocument}
        errorCode={errorCode}
        retryAfterSeconds={retryAfterSeconds}
      />
    );
  }

  if (phase === "identity_confirm" && pendingFullName) {
    return (
      <IdentityConfirmGate
        fullName={pendingFullName}
        onConfirm={handleConfirmIdentity}
        onReject={handleRejectIdentity}
        errorCode={errorCode}
      />
    );
  }

  if (phase === "identity_rejected") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center">
        <h1 className="text-xl font-semibold">
          {t("employee_portal.identity_rejected_title", "Accés cancel·lat")}
        </h1>
        <p className="text-muted-foreground mt-3 text-sm">
          {t(
            "employee_portal.identity_rejected_message",
            "Has indicat que no ets la persona associada a aquest enllaç. Pots tancar aquesta pàgina.",
          )}
        </p>
      </div>
    );
  }

  if (phase === "identity_not_configured") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center">
        <h1 className="text-xl font-semibold">
          {t(
            "employee_portal.identity_not_configured_title",
            "No podem verificar la teva identitat",
          )}
        </h1>
        <p className="text-muted-foreground mt-3 text-sm">
          {t(
            "employee_portal.identity_not_configured_message",
            "No podem verificar la teva identitat perquè falta el document a l'empresa. Contacta recursos humans.",
          )}
        </p>
      </div>
    );
  }

  if (phase === "pin_setup") {
    return (
      <PinSetupGate
        onSubmit={handleSetupPin}
        errorCode={errorCode}
        retryAfterSeconds={retryAfterSeconds}
      />
    );
  }

  if (phase === "pin") {
    return (
      <PinGate
        onSubmit={(pin) => openSession(pin)}
        errorCode={errorCode}
        retryAfterSeconds={retryAfterSeconds}
      />
    );
  }

  if (phase === "error") {
    return (
      <div className="mx-auto max-w-md px-4 py-16 text-center">
        <h1 className="text-xl font-semibold">
          {errorCode === "token_invalid"
            ? t("employee_portal.expired_title", "Enllaç caducat o revocat")
            : t("employee_portal.bootstrap_error", "No s'ha pogut obrir el portal")}
        </h1>
        <p className="text-muted-foreground mt-2 text-sm">
          {errorCode === "token_invalid"
            ? t(
                "employee_portal.expired_message",
                "Demana un enllaç nou al teu responsable per accedir al portal.",
              )
            : errorCode === "identity_required"
              ? t(
                  "employee_portal.identity_required",
                  "Cal verificar la teva identitat abans de continuar.",
                )
              : errorCode}
        </p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-md px-4 py-16 text-center text-sm">
      {t("employee_portal.bootstrap_loading", "Obrint sessió segura…")}
    </div>
  );
}

export default function EmployeePortalBootstrapPage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto max-w-md px-4 py-16 text-center text-sm">…</div>
      }
    >
      <EmployeePortalBootstrapInner />
    </Suspense>
  );
}
