/** Enrich resolve payloads so the reader can show the same OS title as the bulletin list. */

type AdminClient = {
  from: (table: string) => {
    select: (columns: string) => {
      eq: (
        column: string,
        value: string,
      ) => {
        maybeSingle: () => Promise<{ data: Record<string, unknown> | null }>
      }
    }
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function readTitle(intervention: Record<string, unknown>): string {
  return typeof intervention.title === "string" ? intervention.title.trim() : ""
}

export async function enrichResolveWithBulletinTitle(
  admin: AdminClient,
  row: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const projection = asRecord(row.projection)
  if (!projection) return row

  const intervention = { ...(asRecord(projection.intervention) ?? {}) }
  const existing = readTitle(intervention)
  if (existing) {
    return {
      ...row,
      title: existing,
      projection: {
        ...projection,
        intervention: { ...intervention, title: existing },
      },
    }
  }

  let projectId =
    typeof intervention.project_id === "string" && intervention.project_id
      ? intervention.project_id
      : null

  if (!projectId && typeof row.report_version_id === "string") {
    const { data } = await admin
      .from("customer_intervention_report_versions")
      .select("project_id")
      .eq("id", row.report_version_id)
      .maybeSingle()
    if (data?.project_id) projectId = String(data.project_id)
  }

  if (!projectId) return row

  const { data: project } = await admin
    .from("projects")
    .select("name")
    .eq("id", projectId)
    .maybeSingle()

  const title = typeof project?.name === "string" ? project.name.trim() : ""
  if (!title) return row

  return {
    ...row,
    title,
    projection: {
      ...projection,
      intervention: {
        ...intervention,
        project_id: projectId,
        title,
      },
    },
  }
}
