import type { PortalPauseConfig } from "../api/portalApi";

export function portalPauseLabel(config: PortalPauseConfig, lang = "ca"): string {
  return config.label_i18n?.[lang] ?? config.label_i18n?.es ?? config.key;
}
