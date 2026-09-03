"use client";

import { useMemo, useState } from "react";

const KEYS = [
  ["1", "2", "3"],
  ["4", "5", "6"],
  ["7", "8", "9"],
  ["A", "0", "B"],
  ["C", "D", "E"],
  ["F", "G", "H"],
  ["J", "K", "L"],
  ["M", "N", "P"],
  ["Q", "R", "S"],
  ["T", "U", "V"],
  ["W", "X", "Y"],
  ["Z", "", ""],
] as const;

type Props = {
  disabled?: boolean;
  minLength: number;
  matchMode: "exact" | "suffix";
  onSubmit: (documentId: string) => void;
  error?: string | null;
};

export function StationDocumentPad({
  disabled,
  minLength,
  matchMode,
  onSubmit,
  error,
}: Props) {
  const [value, setValue] = useState("");

  const hint = useMemo(() => {
    if (matchMode === "exact") {
      return "Introdueix el document complet (DNI/NIE amb lletra).";
    }
    return `Introdueix almenys els darrers ${minLength} caràcters del document (o el document complet).`;
  }, [matchMode, minLength]);

  function append(ch: string) {
    if (disabled || !ch) return;
    setValue((prev) => (prev + ch).slice(0, 20));
  }

  function backspace() {
    if (disabled) return;
    setValue((prev) => prev.slice(0, -1));
  }

  function clearAll() {
    if (disabled) return;
    setValue("");
  }

  function submit() {
    if (disabled) return;
    const trimmed = value.trim().toUpperCase();
    if (!trimmed) return;
    onSubmit(trimmed);
  }

  return (
    <div className="space-y-4 rounded-2xl border p-4">
      <div>
        <p className="text-sm text-muted-foreground">{hint}</p>
        <div className="mt-2 min-h-[3.25rem] rounded-xl border bg-muted/30 px-4 py-3 font-mono text-2xl tracking-[0.2em]">
          {value || <span className="text-muted-foreground tracking-normal">—</span>}
        </div>
      </div>

      {error ? (
        <p className="rounded-xl border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <div className="grid gap-2">
        {KEYS.map((row, idx) => (
          <div key={idx} className="grid grid-cols-3 gap-2">
            {row.map((key, keyIdx) =>
              key ? (
                <button
                  key={`${key}-${keyIdx}`}
                  type="button"
                  disabled={disabled}
                  onClick={() => append(key)}
                  className="rounded-xl border px-3 py-3 text-lg font-semibold hover:bg-muted disabled:opacity-50"
                >
                  {key}
                </button>
              ) : (
                <span key={`spacer-${keyIdx}`} />
              ),
            )}
          </div>
        ))}
      </div>

      <div className="grid grid-cols-3 gap-2">
        <button
          type="button"
          disabled={disabled}
          onClick={clearAll}
          className="rounded-xl border px-3 py-3 text-sm font-medium hover:bg-muted disabled:opacity-50"
        >
          Esborrar
        </button>
        <button
          type="button"
          disabled={disabled}
          onClick={backspace}
          className="rounded-xl border px-3 py-3 text-sm font-medium hover:bg-muted disabled:opacity-50"
        >
          ⌫
        </button>
        <button
          type="button"
          disabled={disabled || value.trim().length === 0}
          onClick={submit}
          className="rounded-xl bg-primary px-3 py-3 text-sm font-semibold text-primary-foreground disabled:opacity-50"
        >
          Continuar
        </button>
      </div>
    </div>
  );
}
