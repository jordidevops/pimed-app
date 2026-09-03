import {
  ArrowLeftRight,
  CalendarClock,
  CalendarDays,
  ClipboardList,
  Clock,
  FileText,
  History,
  KeyRound,
  Newspaper,
  Palmtree,
  QrCode,
  Shield,
  UserRound,
  UserPlus,
  type LucideIcon,
} from "lucide-react";

export interface PortalNavItem {
  href: string;
  labelKey: string;
  labelFallback: string;
  icon: LucideIcon;
  requiresContentModule?: boolean;
}

export const PORTAL_NAV_ITEMS: PortalNavItem[] = [
  {
    href: "/portal/punch",
    labelKey: "employee_portal.nav_punch",
    labelFallback: "Fitxatge",
    icon: Clock,
  },
  {
    href: "/portal/station-qr",
    labelKey: "employee_portal.nav_station_qr",
    labelFallback: "QR estació",
    icon: QrCode,
  },
  {
    href: "/portal/schedule",
    labelKey: "employee_portal.nav_schedule",
    labelFallback: "Horari",
    icon: CalendarDays,
  },
  {
    href: "/portal/shifts",
    labelKey: "employee_portal.nav_shifts",
    labelFallback: "Els meus torns",
    icon: CalendarClock,
  },
  {
    href: "/portal/openings",
    labelKey: "employee_portal.nav_openings",
    labelFallback: "Vacants",
    icon: UserPlus,
  },
  {
    href: "/portal/swaps",
    labelKey: "employee_portal.nav_swaps",
    labelFallback: "Intercanvis",
    icon: ArrowLeftRight,
  },
  {
    href: "/portal/absences",
    labelKey: "employee_portal.nav_absences",
    labelFallback: "Absències",
    icon: Palmtree,
  },
  {
    href: "/portal/history",
    labelKey: "employee_portal.nav_history",
    labelFallback: "Historial",
    icon: History,
  },
  {
    href: "/portal/documents",
    labelKey: "employee_portal.nav_documents",
    labelFallback: "Documents",
    icon: FileText,
  },
  {
    href: "/portal/news",
    labelKey: "employee_portal.nav_news",
    labelFallback: "Notícies",
    icon: Newspaper,
    requiresContentModule: true,
  },
  {
    href: "/portal/monthly",
    labelKey: "employee_portal.nav_record",
    labelFallback: "Registre",
    icon: ClipboardList,
  },
  {
    href: "/portal/access",
    labelKey: "employee_portal.nav_access",
    labelFallback: "Accessos",
    icon: Shield,
  },
  {
    href: "/portal/personal-data",
    labelKey: "employee_portal.nav_personal_data",
    labelFallback: "Les meves dades",
    icon: UserRound,
  },
  {
    href: "/portal/security",
    labelKey: "employee_portal.nav_security",
    labelFallback: "Seguretat",
    icon: KeyRound,
  },
];
