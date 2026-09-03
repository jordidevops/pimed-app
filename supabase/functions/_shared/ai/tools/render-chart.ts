import { defineTool } from "./define-tool.ts";
import { buildChartUiBlock, RenderChartInput } from "./chart-block.ts";

export const renderChartTool = defineTool({
  name: "render_chart",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: RenderChartInput,
  async execute(_ctx, params) {
    const block = buildChartUiBlock(params);
    return { ok: true, uiBlocks: [block] };
  },
});
