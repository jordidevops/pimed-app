import { z } from "zod";
import {
  CalendarEventRowPublic,
  QueryCalendarEventsInput,
} from "../schemas/tools/query-calendar-events.input.ts";
import { defineTool } from "./define-tool.ts";

export { QueryCalendarEventsInput } from "../schemas/tools/query-calendar-events.input.ts";

export const queryCalendarEventsTool = defineTool({
  name: "query_calendar_events",
  risk: "read",
  requiresSite: true,
  requiredPermission: "calendar.view",
  parameters: QueryCalendarEventsInput,
  async execute(ctx, params, adminClient) {
    if (!ctx.siteId) {
      return { ok: false, error: "site_id required for calendar queries" };
    }

    const { data, error } = await adminClient.rpc("search_calendar_events_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_site_id: ctx.siteId,
      p_from: params.from,
      p_to: params.to,
      p_limit: params.limit ?? 50,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    const rawRows = Array.isArray(data) ? data : [];
    const publicRows: z.infer<typeof CalendarEventRowPublic>[] = [];

    for (const row of rawRows) {
      const parsed = CalendarEventRowPublic.safeParse(row);
      if (parsed.success) publicRows.push(parsed.data);
    }

    return { ok: true, data: publicRows };
  },
});
