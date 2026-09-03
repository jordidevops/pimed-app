import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { EMPLOYEE_PORTAL_SESSION_COOKIE } from "@/lib/employee-portal/constants";
import { PortalSessionRefresh } from "@/features/employee-portal/components/PortalSessionRefresh";
import { PortalShell } from "@/features/employee-portal/components/PortalShell";

export default async function EmployeePortalProtectedLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const cookieStore = await cookies();
  const hasSession = Boolean(cookieStore.get(EMPLOYEE_PORTAL_SESSION_COOKIE)?.value);

  if (!hasSession) {
    redirect("/portal/expired");
  }

  return (
    <>
      <PortalSessionRefresh />
      <PortalShell>{children}</PortalShell>
    </>
  );
}
