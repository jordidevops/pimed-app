/**
 * liquid-renderer.ts — Motor de renderitzat de plantilles LiquidJS
 *
 * Motor únic per a:
 *   - Plantilles de correu electrònic (subject, body, layout)
 *   - Plantilles de documents HTML (signing i generate_only)
 *
 * Sintaxi suportada:
 *   - Interpolació:  {{ variable }}, {{ object.field }}
 *   - Condicionals:  {% if cond %} ... {% endif %}
 *   - Negació:       {% unless cond %} ... {% endunless %}
 *   - Loops:         {% for item in list %} ... {% endfor %}
 *   - Filtres:       {{ value | upcase }}, {{ date | date: "%d/%m/%Y" }}
 *
 * Disseny:
 *   - strictVariables: false → variables absents → empty string, sense error
 *   - Sense auto-escape: les plantilles es consideren contingut de sistema
 *     (authoria de tenant admin) i els valors venen de la BD del propi tenant.
 *   - Si en el futur les plantilles es comparteixen entre tenants, activar
 *     `outputEscape: "escape"` i usar el filtre `| raw` per a HTML de sistema.
 */

import { Liquid } from "npm:liquidjs@10";

const engine = new Liquid({
  strictVariables: false,
  strictFilters:   false,
});

/**
 * Renderitza una plantilla Liquid amb el context donat.
 * Llança Error si la sintaxi de la plantilla és invàlida o si el render falla.
 */
export async function renderLiquid(
  template: string,
  context: Record<string, unknown>,
): Promise<string> {
  try {
    return await engine.parseAndRender(template, context);
  } catch (err) {
    const msg = (err as Error).message ?? String(err);
    throw new Error(`template_syntax_error: ${msg}`);
  }
}

/**
 * Valida sintàcticament una plantilla Liquid.
 * Retorna null si és vàlida, o el missatge d'error si no ho és.
 */
export function validateLiquidSyntax(template: string): string | null {
  try {
    engine.parse(template);
    return null;
  } catch (err) {
    return (err as Error).message ?? String(err);
  }
}
