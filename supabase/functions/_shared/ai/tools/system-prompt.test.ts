import { assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildToolsSystemAppendix } from "./system-prompt.ts";

Deno.test("tools appendix uses effective names and keeps tool ids", () => {
  const appendix = buildToolsSystemAppendix(
    [{
      type: "function",
      function: {
        name: "query_project_price_sheet",
        description: "Consulta el full intern",
        parameters: { type: "object", properties: {} },
      },
    }],
    { projectLabel: "Obres", priceSheetLabel: "Imports" },
  );
  assertStringIncludes(appendix, "Obres");
  assertStringIncludes(appendix, "Imports");
  assertStringIncludes(appendix, "query_project_price_sheet");
  assertStringIncludes(appendix, "propose_price_sheet");
});
