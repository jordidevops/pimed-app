type StationBrandingHeaderProps = {
  title: string;
  logoUrl?: string | null;
  subtitle?: string | null;
  meta?: string | null;
  compact?: boolean;
};

export function StationBrandingHeader({
  title,
  logoUrl,
  subtitle,
  meta,
  compact = false,
}: StationBrandingHeaderProps) {
  return (
    <div className="flex items-start gap-3">
      {logoUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={logoUrl}
          alt=""
          className={
            compact
              ? "h-10 w-10 shrink-0 rounded-lg border bg-background object-contain p-1"
              : "h-14 w-14 shrink-0 rounded-xl border bg-background object-contain p-1.5"
          }
        />
      ) : null}
      <div className="min-w-0">
        <h1 className={compact ? "text-lg font-semibold truncate" : "text-2xl font-semibold"}>
          {title}
        </h1>
        {subtitle ? (
          <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>
        ) : null}
        {meta ? <p className="text-xs text-muted-foreground">{meta}</p> : null}
      </div>
    </div>
  );
}
