import { Suspense } from "react";
import { PortalNewsDetailPage } from "@/features/employee-portal/components/PortalNewsDetailPage";

function NewsDetailPageFallback() {
  return (
    <div className="text-muted-foreground flex justify-center py-12 text-sm">
      …
    </div>
  );
}

export default function NewsDetailPage() {
  return (
    <Suspense fallback={<NewsDetailPageFallback />}>
      <PortalNewsDetailPage />
    </Suspense>
  );
}
