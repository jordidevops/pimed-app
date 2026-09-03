import { Suspense } from "react";
import { PortalDocumentsPage } from "@/features/employee-portal/components/PortalDocumentsPage";

function DocumentsPageFallback() {
  return (
    <div className="text-muted-foreground flex justify-center py-12 text-sm">
      …
    </div>
  );
}

export default function DocumentsPage() {
  return (
    <Suspense fallback={<DocumentsPageFallback />}>
      <PortalDocumentsPage />
    </Suspense>
  );
}
