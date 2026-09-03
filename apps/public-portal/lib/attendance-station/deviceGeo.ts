export type StationDeviceGeo = {
  latitude: number;
  longitude: number;
  accuracy_meters?: number;
  timestamp: string;
};

function mapGeolocationError(code: number): string {
  switch (code) {
    case 1:
      return "station_geo_denied";
    case 2:
      return "station_geo_unavailable";
    case 3:
      return "station_geo_timeout";
    default:
      return "station_geo_unavailable";
  }
}

/** One-shot geolocation probe for station geo anti-fraud (not stored on punch). */
export function getStationDeviceGeo(): Promise<StationDeviceGeo> {
  if (typeof navigator === "undefined" || !navigator.geolocation) {
    return Promise.reject(new Error("station_geo_unavailable"));
  }

  return new Promise((resolve, reject) => {
    navigator.geolocation.getCurrentPosition(
      (position) => {
        resolve({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          accuracy_meters: position.coords.accuracy,
          timestamp: new Date(position.timestamp).toISOString(),
        });
      },
      (err) => reject(new Error(mapGeolocationError(err.code))),
      {
        enableHighAccuracy: true,
        timeout: 15_000,
        maximumAge: 0,
      },
    );
  });
}
