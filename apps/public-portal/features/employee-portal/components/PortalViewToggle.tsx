"use client";

import { cn } from "@/lib/utils";

export interface PortalViewToggleOption<T extends string> {
  value: T;
  label: string;
}

interface PortalViewToggleProps<T extends string> {
  value: T;
  options: PortalViewToggleOption<T>[];
  onChange: (value: T) => void;
  ariaLabel: string;
  className?: string;
}

export function PortalViewToggle<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
  className,
}: PortalViewToggleProps<T>) {
  return (
    <div
      role="group"
      aria-label={ariaLabel}
      className={cn("bg-muted/50 flex w-full rounded-xl border p-1", className)}
    >
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            aria-pressed={active}
            onClick={() => onChange(opt.value)}
            className={cn(
              "flex-1 rounded-lg px-3 py-2.5 text-center text-sm font-medium transition",
              active
                ? "bg-background text-foreground shadow-sm ring-1 ring-border"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
