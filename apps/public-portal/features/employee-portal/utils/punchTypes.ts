export type PortalPunchType =
  | "in"
  | "out"
  | "break_start"
  | "break_end"
  | "day_start"
  | "day_end"
  | "travel_start"
  | "travel_end";

export interface PortalPunchLike {
  punch_type: string;
  pause_type?: string | null;
}
