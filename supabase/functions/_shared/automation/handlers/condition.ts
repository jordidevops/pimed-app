/**
 * handlers/condition.ts
 *
 * Avalua una condició i retorna el nextStepId corresponent (if_true o if_false).
 * El template engine ja ha resolt els valors de l'expressió abans d'arribar aquí.
 *
 * Config esperada:
 * {
 *   "expression_left": "{{ context.entity.source }}",  // ja resolt pel template engine
 *   "operator": "eq" | "neq" | "contains" | "gt" | "lt" | "exists",
 *   "expression_right": "web_contact_form",
 *   "if_true": "step_2a",
 *   "if_false": "step_2b"
 * }
 */

import type { AdminClient } from "../../queue-runtime.ts";
import type { StepHandlerResult, WorkflowContext } from "../types.ts";
import { log } from "../../observability/structured-logger.ts";

const FEATURE = "handler:condition";

type ConditionOperator = "eq" | "neq" | "contains" | "gt" | "lt" | "exists";

function evaluateCondition(
  left: string,
  operator: ConditionOperator,
  right: string,
): boolean {
  switch (operator) {
    case "eq":
      return left === right;
    case "neq":
      return left !== right;
    case "contains":
      return left.includes(right);
    case "gt": {
      const lNum = parseFloat(left);
      const rNum = parseFloat(right);
      return !isNaN(lNum) && !isNaN(rNum) && lNum > rNum;
    }
    case "lt": {
      const lNum = parseFloat(left);
      const rNum = parseFloat(right);
      return !isNaN(lNum) && !isNaN(rNum) && lNum < rNum;
    }
    case "exists":
      return left !== "" && left !== "null" && left !== "undefined";
    default:
      return false;
  }
}

export async function conditionHandler(
  _db: AdminClient,
  config: Record<string, unknown>,
  context: WorkflowContext,
): Promise<StepHandlerResult> {
  const tenantId = context.tenant.id;

  // Els valors ja han estat resolts pel template engine en step-executor
  const left = String(config.expression_left ?? "");
  const operator = String(config.operator ?? "eq") as ConditionOperator;
  const right = String(config.expression_right ?? "");
  const ifTrue = String(config.if_true ?? "END_OK");
  const ifFalse = String(config.if_false ?? "END_OK");

  const result = evaluateCondition(left, operator, right);
  const nextStepId = result ? ifTrue : ifFalse;

  log("info", FEATURE, "Condition evaluated", {
    tenantId,
    extra: { left, operator, right, result, nextStepId },
  });

  return {
    success: true,
    nextStepId,
    output: { condition_result: result, next_step_id: nextStepId },
  };
}
