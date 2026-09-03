import { Suspense } from "react";
import { PortalMonthlyPage } from "@/features/employee-portal/components/PortalMonthlyPage";

function MonthlyPageFallback() {
  return (
    <div className="text-muted-foreground flex justify-center py-12 text-sm">
      …
    </div>
  );
}

export default function MonthlyPage() {
  return (
    <Suspense fallback={<MonthlyPageFallback />}>
      <PortalMonthlyPage />
    </Suspense>
  );
}
