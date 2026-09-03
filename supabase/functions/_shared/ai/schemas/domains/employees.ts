import { z } from "zod";

/** Camps exposats al model després de query_employees (sense email ni document). */
export const EmployeeRowPublic = z.object({
  id: z.string().uuid(),
  full_name: z.string(),
  job_position_id: z.string().uuid().nullable().optional(),
  job_position_name: z.string().nullable().optional(),
  status: z.string(),
  department_id: z.string().uuid().nullable().optional(),
});

export type EmployeeRowPublic = z.infer<typeof EmployeeRowPublic>;
