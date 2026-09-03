import type { DefinedTool } from "./define-tool.ts";
import { queryEmployeesTool } from "./query-employees.ts";
import { queryEmployeesBySkillsTool } from "./query-employees-by-skills.ts";
import { querySkillCoverageTool } from "./query-skill-coverage.ts";
import { queryEntityTimelineTool } from "./query-entity-timeline.ts";
import { postEntityTimelineCommentTool } from "./post-entity-timeline-comment.ts";
import { queryCalendarEventsTool } from "./query-calendar-events.ts";
import { renderChartTool } from "./render-chart.ts";
import { proposeUpdateEmployeeTool } from "./propose-update-employee.ts";
import { proposeCreateAlertTool } from "./propose-create-alert.ts";
import { queryDocumentTemplatesTool } from "./query-document-templates.ts";
import { queryTemplateLocaleTool } from "./query-template-locale.ts";
import { openDocumentGeneratorTool } from "./open-document-generator.ts";
import { proposeCreateContactTool } from "./propose-create-contact.ts";
import { proposeExtractStructuredDataTool } from "./propose-extract-structured-data.ts";
import { hasToolPermission } from "./permissions.ts";
import type { ProviderToolSchema, ToolExecutionContext } from "./types.ts";
import { z } from "zod";

const ALL_TOOLS: DefinedTool<z.ZodTypeAny>[] = [
  queryEmployeesTool,
  queryEmployeesBySkillsTool,
  querySkillCoverageTool,
  queryEntityTimelineTool,
  postEntityTimelineCommentTool,
  queryCalendarEventsTool,
  queryDocumentTemplatesTool,
  queryTemplateLocaleTool,
  openDocumentGeneratorTool,
  renderChartTool,
  proposeUpdateEmployeeTool,
  proposeCreateContactTool,
  proposeExtractStructuredDataTool,
  proposeCreateAlertTool,
];

const CRON_ANALYTICS_TOOL_NAMES = new Set([
  "query_employees",
  "query_employees_by_skills",
  "query_skill_coverage",
  "query_entity_timeline",
  "query_calendar_events",
  "propose_create_alert",
]);

export function listToolsForContext(
  ctx: ToolExecutionContext,
): Array<DefinedTool<z.ZodTypeAny> & { getProviderSchema: () => ProviderToolSchema }> {
  if (!hasToolPermission(ctx, "ai.use")) {
    return [];
  }

  return ALL_TOOLS.filter((tool) => {
    if (ctx.feature === "cron_analytics" && !CRON_ANALYTICS_TOOL_NAMES.has(tool.name)) {
      return false;
    }
    if (ctx.feature === "chat" && tool.name === "propose_create_alert") {
      return false;
    }
    if (tool.requiresSite && !ctx.siteId) return false;
    if (tool.requiresImages && ctx.metadata?.hasAttachments !== true) return false;
    if (tool.requiredPermission && !hasToolPermission(ctx, tool.requiredPermission)) {
      return false;
    }
    if (tool.risk === "write" && !hasToolPermission(ctx, "ai.tools.write")) {
      return false;
    }
    return true;
  });
}

export function getToolByName(name: string): DefinedTool<z.ZodTypeAny> | undefined {
  const normalized = name.replace(/^default_api:/, "");
  return ALL_TOOLS.find((t) => t.name === normalized || t.name === name);
}

export function listProviderSchemas(ctx: ToolExecutionContext): ProviderToolSchema[] {
  return listToolsForContext(ctx).map((t) => t.getProviderSchema());
}
