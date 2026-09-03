import type { LucideIcon } from "lucide-react";
import {
  Coffee,
  CupSoda,
  PauseCircle,
  Stethoscope,
  UtensilsCrossed,
} from "lucide-react";

/** Mateixa mida que PortalPunchButton — evita desplaçaments en canviar d'estat. */
export const PORTAL_PUNCH_HERO_CLASS = "h-48 w-48";

/** Espai reservat sota el botó rodó per accions secundàries (evita salt vertical). */
export const PORTAL_PUNCH_SECONDARY_SLOT_CLASS = "min-h-[4.5rem]";

const PAUSE_ICON_BY_KEY: Record<string, LucideIcon> = {
  lunch: UtensilsCrossed,
  rest: Coffee,
  medical: Stethoscope,
  break: Coffee,
  coffee: CupSoda,
  meal: UtensilsCrossed,
  diner: UtensilsCrossed,
  dinar: UtensilsCrossed,
  menjar: UtensilsCrossed,
  comida: UtensilsCrossed,
  descans: Coffee,
  descanso: Coffee,
  metge: Stethoscope,
  doctor: Stethoscope,
};

export function getPortalPauseIcon(key: string): LucideIcon {
  const normalized = key.toLowerCase().trim();
  if (PAUSE_ICON_BY_KEY[normalized]) return PAUSE_ICON_BY_KEY[normalized];

  for (const [fragment, icon] of Object.entries(PAUSE_ICON_BY_KEY)) {
    if (normalized.includes(fragment)) return icon;
  }

  return PauseCircle;
}
