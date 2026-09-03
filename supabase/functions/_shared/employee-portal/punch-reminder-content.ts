import type { PunchReminderKind } from "./punch-reminder-eval.ts";

export function buildPunchReminderNotification(
  kind: PunchReminderKind,
  workDate: string,
): { title: string; body: string; url: string; tag: string } {
  const tag = `punch-reminder-${kind}-${workDate}`;

  switch (kind) {
    case "missing_entry":
      return {
        title: "Falta fitxatge d'entrada",
        body: "Hauries d'haver fitxat l'entrada. Obre el portal per registrar-la.",
        url: "/portal/punch",
        tag,
      };
    case "missing_afternoon_entry":
      return {
        title: "Falta fitxatge de tarda",
        body: "Hauries d'haver fitxat l'entrada de la tarda. Obre el portal per registrar-la.",
        url: "/portal/punch",
        tag,
      };
    case "missing_morning_exit":
      return {
        title: "Falta sortida de matí",
        body: "No has fitxat la sortida del torn de matí. Si ja has acabat, fitxa sortida.",
        url: "/portal/punch",
        tag,
      };
    case "missing_exit":
      return {
        title: "Falta fitxatge de sortida",
        body: "La jornada hauria d'haver acabat. Recorda fitxar la sortida.",
        url: "/portal/punch",
        tag,
      };
    case "starting_soon":
      return {
        title: "La jornada comença aviat",
        body: "La teva jornada comença aviat. Recorda fitxar l'entrada.",
        url: "/portal/punch",
        tag,
      };
    case "afternoon_starting_soon":
      return {
        title: "La tarda comença aviat",
        body: "La sessió de tarda comença aviat. Recorda fitxar l'entrada.",
        url: "/portal/punch",
        tag,
      };
    default:
      return {
        title: "Recordatori de fitxatge",
        body: "Tens un recordatori de fitxatge pendent.",
        url: "/portal/punch",
        tag,
      };
  }
}
