import { Suspense } from "react";
import { PortalNewsPage } from "@/features/employee-portal/components/PortalNewsPage";

function NewsPageFallback() {
  return (
    <div className="text-muted-foreground flex justify-center py-12 text-sm">
      …
    </div>
  );
}

export default function NewsPage() {
  return (
    <Suspense fallback={<NewsPageFallback />}>
      <PortalNewsPage />
    </Suspense>
  );
}
