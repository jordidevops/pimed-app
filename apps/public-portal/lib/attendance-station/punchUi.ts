export type StationDayState = "off" | "day" | "work" | "break" | "travel" | "unknown";

export type StationEmployeeRow = {
  employee_id: string;
  full_name: string;
  last_punch_type: string | null;
  last_punch_at: string | null;
  day_state?: StationDayState | null;
  next_punch?: "in" | "out" | "break_end" | null;
  active_pause_type?: string | null;
  can_start_pause?: boolean;
  can_end_pause?: boolean;
};

export function stationDayStateLabel(state: StationDayState | null | undefined): string {
  switch (state) {
    case "work":
      return "Treballant";
    case "day":
      return "Fora (entre entrades)";
    case "off":
      return "Sense fitxar avui";
    case "break":
      return "En pausa";
    case "travel":
      return "En desplaçament";
    case "unknown":
      return "Seqüència no vàlida";
    default:
      return "—";
  }
}

export function stationBlockedMessage(state: StationDayState | null | undefined): string {
  switch (state) {
    case "break":
      return "Tanca la pausa des del portal mòbil abans de fitxar aquí.";
    case "travel":
      return "Finalitza el desplaçament des del portal mòbil abans de fitxar aquí.";
    case "unknown":
      return "La seqüència de fitxatges d'avui no és vàlida. Contacta amb administració.";
    default:
      return "Ara no es pot fitxar des d'aquesta estació.";
  }
}

export function formatStationPunchError(message: string): string {
  if (message.includes("station_wrong_punch_type")) {
    if (message.includes("expected out")) {
      return "Aquest empleat ja ha fitxat entrada. Cal registrar sortida.";
    }
    if (message.includes("expected in")) {
      return "Aquest empleat no té entrada oberta. Cal registrar entrada primer.";
    }
    return "Acció de fitxatge incorrecta per l'estat actual de l'empleat.";
  }
  if (message.includes("station_punch_blocked")) {
    if (message.includes("state break")) {
      return stationBlockedMessage("break");
    }
    if (message.includes("state travel")) {
      return stationBlockedMessage("travel");
    }
    return stationBlockedMessage("unknown");
  }
  if (message.includes("day_start required before in")) {
    return "Aquest empleat necessita inici de jornada al portal mòbil. A l'estació només es permet Entrada/Sortida.";
  }
  if (message.includes("invalid_sequence")) {
    if (message.includes("cannot out after")) {
      return "No es pot registrar sortida: l'empleat no té una entrada oberta avui.";
    }
    if (message.includes("cannot in after")) {
      return "No es pot registrar entrada: l'empleat ja té una jornada oberta.";
    }
    return "Seqüència de fitxatge no vàlida per avui. Revisa l'últim fitxatge de l'empleat.";
  }
  if (message.includes("station_register_rate_limited")) {
    return "Massa intents d'aparellament. Espera uns minuts i torna-ho a provar.";
  }
  if (message.includes("station_identity_issue_rate_limited")) {
    return "Has generat massa codis QR seguits. Espera uns minuts abans de renovar.";
  }
  if (message.includes("station_identity_resolve_rate_limited")) {
    return "Massa intents de lectura de QR. Espera uns minuts i torna-ho a provar.";
  }
  if (message.includes("identity_token_expired")) {
    return "El QR ha caducat. Genera'n un de nou al mòbil.";
  }
  if (message.includes("identity_token_required")) {
    return "Cal escanejar el QR de l'empleat abans de confirmar el fitxatge.";
  }
  if (
    message.includes("missing_station_auth")
    || message.includes("station_invalid_secret")
    || message.includes("station_auth_failed")
    || message.includes("station_not_found")
    || message.includes("station_error")
  ) {
    return "Aquesta estació ha de tornar a aparellar-se. Demana un codi nou a administració.";
  }
  if (message.includes("identity_token_already_used")) {
    return "Aquest QR ja s'ha utilitzat. Genera'n un de nou al mòbil.";
  }
  if (message.includes("identity_token_invalid")) {
    return "QR no vàlid. Genera'n un de nou al mòbil.";
  }
  if (message.includes("station_qr_not_allowed")) {
    return "Aquesta estació no té el mètode QR habilitat.";
  }
  if (message.includes("employee_not_allowed_at_location")) {
    return "Aquest empleat no està assignat a aquesta zona de fitxatge.";
  }
  if (message.includes("wrong_scheduled_location")) {
    return "Aquesta estació no coincideix amb la ubicació planificada d'avui. Contacta amb administració o fes servir l'estació correcta.";
  }
  if (message.includes("station_punch_not_monotonic")) {
    return "Aquest fitxatge offline és anterior a un ja registrat avui. Queda en quarantena per revisió.";
  }
  if (message.includes("station_punch_too_old")) {
    return "Aquest fitxatge offline és massa antic i no s'ha pogut pujar. Queda en quarantena per revisió.";
  }
  if (message.includes("station_offline_disabled")) {
    return "El fitxatge offline no està actiu per aquest centre. Cal connexió a la xarxa.";
  }
  if (message.includes("missing_pause_type") || message.includes("invalid_pause_type")) {
    return "Cal indicar un tipus de pausa vàlid.";
  }
  if (message.includes("station_wrong_punch_type") && message.includes("break")) {
    return "Ara no es pot registrar aquesta acció de pausa. Revisa l'estat de l'empleat.";
  }
  return message;
}

export function formatStationGeoError(message: string): string {
  if (message.includes("station_geo_denied")) {
    return "Cal permetre l'accés a la ubicació del dispositiu per fitxar en aquesta estació.";
  }
  if (message.includes("station_geo_timeout")) {
    return "No s'ha pogut obtenir la ubicació del dispositiu a temps. Torna-ho a provar.";
  }
  if (message.includes("station_geo_unavailable")) {
    return "Aquest dispositiu no pot obtenir la ubicació. Comprova que el navegador i el sistema ho permetin.";
  }
  if (message.includes("station_geo_required")) {
    return "Aquesta estació requereix validació de ubicació del dispositiu.";
  }
  if (message.includes("station_geo_out_of_range")) {
    return "El dispositiu està massa lluny de la ubicació assignada. Mou la tablet al lloc correcte o contacta amb administració.";
  }
  if (message.includes("station_geo_invalid")) {
    return "La ubicació del dispositiu no és vàlida. Torna-ho a provar.";
  }
  if (message.includes("geo_antifraud_requires_location_geo")) {
    return "La ubicació assignada no té coordenades GPS. Contacta amb administració.";
  }
  return formatStationPunchError(message);
}

export function formatStationCameraError(message: string): string {
  const normalized = message.toLowerCase();

  if (
    normalized.includes("requested device not found") ||
    normalized.includes("notfounderror") ||
    normalized.includes("device not found") ||
    message === "camera_unavailable"
  ) {
    return "No s'ha trobat cap càmera. Connecta una webcam o utilitza la selecció manual.";
  }
  if (
    normalized.includes("notallowederror") ||
    normalized.includes("permission denied") ||
    normalized.includes("permission dismissed")
  ) {
    return "Cal permetre l'accés a la càmera al navegador per escanejar el QR.";
  }
  if (normalized.includes("notreadableerror") || normalized.includes("could not start video source")) {
    return "La càmera no està disponible. Potser una altra aplicació l'està utilitzant.";
  }
  if (normalized.includes("overconstrainederror")) {
    return "La càmera connectada no compleix els requisits per escanejar el QR.";
  }

  return "No s'ha pogut iniciar la càmera. Prova de refrescar la pàgina o utilitza la selecció manual.";
}
