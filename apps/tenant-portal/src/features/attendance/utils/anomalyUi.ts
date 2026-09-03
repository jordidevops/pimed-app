/** Metadades UI per codis d'anomalia (etiqueta + ajuda contextual). */

export interface AnomalyUiMeta {
  labelKey: string
  labelFallback: string
  helpKey?: string
  helpFallback?: string
}

export const ANOMALY_UI: Record<string, AnomalyUiMeta> = {
  outside_location: {
    labelKey: 'anomaly.outside_location',
    labelFallback: 'Fitxatge fora de la ubicació assignada',
  },
  clock_skew: {
    labelKey: 'anomaly.clock_skew',
    labelFallback: 'Diferència horària detectada',
  },
  duplicate: {
    labelKey: 'anomaly.duplicate',
    labelFallback: 'Possible fitxatge duplicat',
  },
  PAUSE_NOT_CLOSED: {
    labelKey: 'anomaly.pause_not_closed',
    labelFallback: 'Pausa sense tancar',
    helpKey: 'anomaly.help_pause_not_closed',
    helpFallback: 'Hi ha una pausa d\'inici sense el fitxatge de fi corresponent.',
  },
  MISSING_IN: {
    labelKey: 'anomaly.missing_in',
    labelFallback: 'Falta entrada',
    helpKey: 'anomaly.help_missing_in',
    helpFallback: 'S\'ha registrat una sortida o pausa sense una entrada prèvia al mateix dia.',
  },
  EXTRA_IN: {
    labelKey: 'anomaly.extra_in',
    labelFallback: 'Entrada extra',
    helpKey: 'anomaly.help_extra_in',
    helpFallback: 'Hi ha més entrades que sortides al mateix dia.',
  },
  EXTRA_OUT: {
    labelKey: 'anomaly.extra_out',
    labelFallback: 'Sortida extra',
    helpKey: 'anomaly.help_extra_out',
    helpFallback: 'Hi ha més sortides que entrades al mateix dia.',
  },
  MISSING_OUT: {
    labelKey: 'anomaly.missing_out',
    labelFallback: 'Falta sortida',
    helpKey: 'anomaly.help_missing_out',
    helpFallback: 'L\'empleat encara està en jornada oberta o falta el fitxatge de sortida.',
  },
  BREAK_MISMATCH: {
    labelKey: 'anomaly.break_mismatch',
    labelFallback: 'Pauses desparellades',
    helpKey: 'anomaly.help_break_mismatch',
    helpFallback: 'El nombre de pauses iniciades no coincideix amb les tancades.',
  },
  CLOCK_SKEW: {
    labelKey: 'anomaly.clock_skew',
    labelFallback: 'Desfasament de rellotge',
    helpKey: 'anomaly.help_clock_skew',
    helpFallback: 'L\'hora del dispositiu difereix notablement de l\'hora del servidor.',
  },
  OFFLINE_DELAY: {
    labelKey: 'anomaly.offline_delay',
    labelFallback: 'Sync offline retardat',
    helpKey: 'anomaly.help_offline_delay',
    helpFallback:
      'El fitxatge s\'ha pujat molt després del moment del toc (cua offline). Revisa occurred_at vs received_at.',
  },
  HIGH_UNCERTAINTY: {
    labelKey: 'anomaly.high_uncertainty',
    labelFallback: 'Geolocalització imprecisa',
    helpKey: 'anomaly.help_high_uncertainty',
    helpFallback: 'El GPS tenia un error superior al llindar; la ubicació pot ser poc fiable.',
  },
  OVERTIME_CLAIMED: {
    labelKey: 'anomaly.overtime_claimed',
    labelFallback: 'Hores extra declarades per l\'empleat',
    helpKey: 'anomaly.help_overtime_claimed',
    helpFallback:
      'En fitxar, l\'empleat ha indicat «He fet hores extra». Cal revisar si correspon aprovar o ajustar el dia.',
  },
  SCHEDULE_HOURS_CLAIMED: {
    labelKey: 'anomaly.schedule_hours_claimed',
    labelFallback: 'Revisió sol·licitada per l\'empleat',
    helpKey: 'anomaly.help_schedule_hours_claimed',
    helpFallback:
      'En fitxar fora de l\'horari previst, l\'empleat ha demanat revisió («He fet l\'horari previst»). Comprova els fitxatges i l\'horari del calendari; confirma o ajusta el registre.',
  },
  MANAGER_CORRECTION: {
    labelKey: 'anomaly.manager_correction',
    labelFallback: 'Correcció de manager',
    helpKey: 'anomaly.help_manager_correction',
    helpFallback: 'Un gestor ha aplicat un ajust manual al registre processat del dia.',
  },
  EFFECTIVE_OVERFLOW_EARLY: {
    labelKey: 'anomaly.effective_overflow_early',
    labelFallback: 'Entrada abans de la cortesia',
    helpKey: 'anomaly.help_effective_overflow_early',
    helpFallback:
      'L\'empleat ha fitxat abans del marge de cortesia sense política que ho accepti com a temps efectiu.',
  },
  EFFECTIVE_OVERFLOW_LATE: {
    labelKey: 'anomaly.effective_overflow_late',
    labelFallback: 'Sortida després de la cortesia',
    helpKey: 'anomaly.help_effective_overflow_late',
    helpFallback:
      'La sortida és posterior al marge de cortesia i no hi ha autorització d\'hores extra.',
  },
  OVERTIME_UNAUTHORIZED: {
    labelKey: 'anomaly.overtime_unauthorized',
    labelFallback: 'Hores extra sense autorització',
    helpKey: 'anomaly.help_overtime_unauthorized',
    helpFallback: 'S\'han calculat hores extra que encara no estan autoritzades.',
  },
  CONSOLIDATION_POLICY_MISSING: {
    labelKey: 'anomaly.consolidation_policy_missing',
    labelFallback: 'Falta política de consolidació',
    helpKey: 'anomaly.help_consolidation_policy_missing',
    helpFallback: 'No s\'ha pogut resoldre cap política de registre per consolidar el dia.',
  },
  SUMMARY_STALE_AFTER_RECONSOLIDATION: {
    labelKey: 'anomaly.summary_stale',
    labelFallback: 'Resum desactualitzat després de reconsolidar',
    helpKey: 'anomaly.help_summary_stale',
    helpFallback:
      'El temps efectiu ha canviat després d\'aprovar el dia. Cal revisar i tornar a aprovar.',
  },
  TRAVEL_NOT_CLOSED: {
    labelKey: 'anomaly.travel_not_closed',
    labelFallback: 'Desplaçament sense tancar',
    helpKey: 'anomaly.help_travel_not_closed',
    helpFallback: 'Hi ha un inici de desplaçament sense arribada o fi de jornada.',
  },
  DAY_NOT_CLOSED: {
    labelKey: 'anomaly.day_not_closed',
    labelFallback: 'Jornada sense tancar',
    helpKey: 'anomaly.help_day_not_closed',
    helpFallback: 'S\'ha registrat l\'inici de jornada però no el tancament (p. ex. fi de jornada).',
  },
  SEGMENT_GAP: {
    labelKey: 'anomaly.segment_gap',
    labelFallback: 'Buit entre segments',
    helpKey: 'anomaly.help_segment_gap',
    helpFallback: 'Hi ha un interval sense classificar entre segments d\'activitat.',
  },
  UNCLASSIFIED_GAP: {
    labelKey: 'anomaly.unclassified_gap',
    labelFallback: 'Temps sense classificar',
    helpKey: 'anomaly.help_unclassified_gap',
    helpFallback:
      'Hi ha un interval entre obres o fitxatges de camp sense declarar el tipus (desplaçament, pausa, etc.).',
  },
  WORK_PROFILE_MISMATCH: {
    labelKey: 'anomaly.work_profile_mismatch',
    labelFallback: 'Fitxatges incompatibles amb el perfil',
    helpKey: 'anomaly.help_work_profile_mismatch',
    helpFallback: 'Els tipus de fitxatge no coincideixen amb el perfil de jornada de l\'empleat.',
  },
  LATE_ARRIVAL: {
    labelKey: 'anomaly.late_arrival',
    labelFallback: 'Arribada tardana',
    helpKey: 'anomaly.help_late_arrival',
    helpFallback: 'L\'entrada és posterior al marge de grace configurat per al perfil.',
  },
  SHORT_BREAK: {
    labelKey: 'anomaly.short_break',
    labelFallback: 'Pausa de migdia massa curta',
    helpKey: 'anomaly.help_short_break',
    helpFallback: 'La pausa entre trams és inferior al mínim de flex_midday.',
  },
  LONG_BREAK: {
    labelKey: 'anomaly.long_break',
    labelFallback: 'Pausa de migdia massa llarga',
    helpKey: 'anomaly.help_long_break',
    helpFallback: 'La pausa entre trams supera el màxim de flex_midday.',
  },
  FLEX_MIDDAY_OUTSIDE_WINDOW: {
    labelKey: 'anomaly.flex_midday_outside',
    labelFallback: 'Pausa de migdia fora de finestra',
    helpKey: 'anomaly.help_flex_midday_outside',
    helpFallback: 'La sortida o el retorn del migdia queden fora de la finestra flex_midday.',
  },
  WRONG_SCHEDULED_LOCATION: {
    labelKey: 'anomaly.wrong_scheduled_location',
    labelFallback: 'Ubicació diferent de la planificada',
    helpKey: 'anomaly.help_wrong_scheduled_location',
    helpFallback:
      'L\'empleat ha fitxat en una estació que no coincideix amb la ubicació del torn publicat.',
  },
  OUTSIDE_ASSIGNMENT: {
    labelKey: 'anomaly.outside_assignment',
    labelFallback: 'Fitxatge fora de l\'assignació de zona',
    helpKey: 'anomaly.help_outside_assignment',
    helpFallback:
      'L\'empleat no té assignació activa a la zona de l\'estació; s\'ha permès el fitxatge amb avís.',
  },
}

export const PUNCH_DISCREPANCY_RESOLUTION_UI: Record<
  string,
  { labelKey: string; labelFallback: string }
> = {
  confirmed_ok: {
    labelKey: 'day_detail.declaration_confirmed_ok',
    labelFallback: 'L\'empleat ha confirmat que el fitxatge és correcte',
  },
  strip_geo: {
    labelKey: 'day_detail.declaration_strip_geo',
    labelFallback: 'L\'empleat ha demanat no conservar la ubicació d\'aquest fitxatge',
  },
  overtime_claimed: {
    labelKey: 'day_detail.declaration_overtime',
    labelFallback: 'L\'empleat declara que ha fet hores extra',
  },
  scheduled_hours_claimed: {
    labelKey: 'day_detail.declaration_schedule',
    labelFallback: 'L\'empleat demana revisió: diu que ha seguit l\'horari previst',
  },
}
