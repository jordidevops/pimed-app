import { z } from "zod";

export const ChartDatasetSchema = z.object({
  label: z.string(),
  values: z.array(z.number()),
});

export const RenderChartInput = z.object({
  chartType: z.enum(["bar", "line", "pie"]).describe("Tipus de gràfic"),
  title: z.string().describe("Títol visible"),
  labels: z.array(z.string()).describe("Etiquetes de l'eix X o sectors"),
  datasets: z.array(ChartDatasetSchema).min(1).describe(
    "Sèries numèriques; cada sèrie ha de tenir tantes values com labels",
  ),
}).superRefine((data, ctx) => {
  for (const [index, dataset] of data.datasets.entries()) {
    if (dataset.values.length !== data.labels.length) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `La sèrie "${dataset.label}" ha de tenir ${data.labels.length} valors`,
        path: ["datasets", index, "values"],
      });
    }
  }
}).describe(
  "Renderitza un gràfic a la UI del xat. Crida query_* abans per obtenir dades reals.",
);

export const ChartUiBlockSchema = z.object({
  type: z.literal("chart"),
  chartType: z.enum(["bar", "line", "pie"]),
  title: z.string(),
  labels: z.array(z.string()),
  datasets: z.array(ChartDatasetSchema),
});

export type ChartUiBlock = z.infer<typeof ChartUiBlockSchema>;

export function buildChartUiBlock(
  input: z.infer<typeof RenderChartInput>,
): ChartUiBlock {
  return ChartUiBlockSchema.parse({
    type: "chart",
    chartType: input.chartType,
    title: input.title,
    labels: input.labels,
    datasets: input.datasets,
  });
}
