import { Suspense } from "react";
import { PortalMyShiftsPage } from "@/features/employee-portal/components/PortalMyShiftsPage";

export default function ShiftsPage() {
  return (
    <Suspense fallback={null}>
      <PortalMyShiftsPage />
    </Suspense>
  );
}
