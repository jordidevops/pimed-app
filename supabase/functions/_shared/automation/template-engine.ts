/**
 * Resolució simplificada de variables {{...}} en strings de configuració.
 * Suporta accés annidat: {{ context.entity.email }}, {{ steps.step_1.output.document_id }}
 * No usa Liquid real — és una substitució de variables basada en regex + path lookup.
 */

const TEMPLATE_RE = /\{\{\s*([^}]+?)\s*\}\}/g;

/**
 * Accedeix a un valor annidat d'un objecte donant un path "a.b.c".
 * Retorna `undefined` si qualsevol node intermedi no existeix.
 */
function getNestedValue(obj: Record<string, unknown>, path: string): unknown {
  const parts = path.split(".");
  let current: unknown = obj;
  for (const part of parts) {
    if (current == null || typeof current !== "object") return undefined;
    current = (current as Record<string, unknown>)[part];
  }
  return current;
}

/**
 * Substitueix totes les ocurrències `{{ path.to.value }}` d'un string
 * amb el valor del context. Si el valor no existeix, substitueix per string buit.
 */
export function resolveTemplate(
  template: string,
  context: Record<string, unknown>,
): string {
  return template.replace(TEMPLATE_RE, (_match, path: string) => {
    const value = getNestedValue(context, path.trim());
    if (value == null) return "";
    return String(value);
  });
}

/**
 * Aplica `resolveTemplate` recursivament a tots els strings d'un objecte de configuració.
 * Arrays i objectes anidats es recorren en profunditat.
 */
export function resolveConfigValues(
  config: Record<string, unknown>,
  context: Record<string, unknown>,
): Record<string, unknown> {
  const resolved: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(config)) {
    if (typeof value === "string") {
      resolved[key] = resolveTemplate(value, context);
    } else if (Array.isArray(value)) {
      resolved[key] = value.map((item) => {
        if (typeof item === "string") return resolveTemplate(item, context);
        if (typeof item === "object" && item !== null) {
          return resolveConfigValues(item as Record<string, unknown>, context);
        }
        return item;
      });
    } else if (typeof value === "object" && value !== null) {
      resolved[key] = resolveConfigValues(
        value as Record<string, unknown>,
        context,
      );
    } else {
      resolved[key] = value;
    }
  }

  return resolved;
}
