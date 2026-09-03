"use client";

type Props = {
  title: string;
  logoUrl?: string | null;
  onWake: () => void;
};

export function StationPrivacyBlank({ title, logoUrl, onWake }: Props) {
  return (
    <button
      type="button"
      onClick={onWake}
      className="fixed inset-0 z-40 flex flex-col items-center justify-center gap-6 bg-slate-950 px-6 text-center text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white"
      aria-label="Toca per activar l'estació"
    >
      {logoUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={logoUrl} alt="" className="h-16 w-auto max-w-[12rem] object-contain opacity-90" />
      ) : null}
      <div>
        <p className="text-sm uppercase tracking-[0.2em] text-slate-400">Estació</p>
        <h1 className="mt-2 text-3xl font-semibold sm:text-4xl">{title}</h1>
      </div>
      <p className="max-w-sm text-base text-slate-300">Toca la pantalla per continuar</p>
    </button>
  );
}
