import { assertEquals, assertSnapshot } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { getProviderSchemaFromZod } from "../lib/provider-schema.ts";
import { QueryEmployeesInput } from "../tools/query-employees.input.ts";
import { QueryCalendarEventsInput } from "../tools/query-calendar-events.input.ts";
import { ProposeExtractStructuredDataInput } from "../tools/propose-extract-structured-data.input.ts";

Deno.test("query_employees provider schema snapshot", () => {
  const schema = getProviderSchemaFromZod("query_employees", QueryEmployeesInput);
  assertEquals(schema.type, "function");
  assertEquals(schema.function.name, "query_employees");
  assertSnapshot("query_employees", schema);
});

Deno.test("query_calendar_events provider schema snapshot", () => {
  const schema = getProviderSchemaFromZod("query_calendar_events", QueryCalendarEventsInput);
  assertEquals(schema.type, "function");
  assertEquals(schema.function.name, "query_calendar_events");
  assertSnapshot("query_calendar_events", schema);
});

Deno.test("propose_extract_structured_data provider schema snapshot", () => {
  const schema = getProviderSchemaFromZod(
    "propose_extract_structured_data",
    ProposeExtractStructuredDataInput,
  );
  assertEquals(schema.type, "function");
  assertEquals(schema.function.name, "propose_extract_structured_data");
  assertSnapshot("propose_extract_structured_data", schema);
});
