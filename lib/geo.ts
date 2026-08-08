import type { LocationStatus, Workplace } from "./types";

export interface LocationResult {
  latitude: number | null;
  longitude: number | null;
  accuracy: number | null;
  distance: number | null;
  status: LocationStatus;
  message: string;
}

const toRadians = (value: number) => (value * Math.PI) / 180;

export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number) {
  const earthRadius = 6_371_000;
  const latitudeDelta = toRadians(lat2 - lat1);
  const longitudeDelta = toRadians(lon2 - lon1);
  const a = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2)) * Math.sin(longitudeDelta / 2) ** 2;
  return Math.round(earthRadius * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
}

export function classifyLocation(latitude: number, longitude: number, accuracy: number, workplace: Workplace): LocationResult {
  const distance = haversineMeters(latitude, longitude, workplace.latitude, workplace.longitude);
  if (accuracy > workplace.low_accuracy_threshold_meters) {
    const roundedAccuracy = Math.round(accuracy);
    return { latitude, longitude, accuracy: roundedAccuracy, distance, status: "low_accuracy", message: `위치 측정 오차가 약 ${roundedAccuracy}m로 커서 사업장 안팎을 판정할 수 없습니다.` };
  }
  if (distance > workplace.allowed_radius_meters) {
    return { latitude, longitude, accuracy: Math.round(accuracy), distance, status: "outside", message: `사업장 기준점에서 약 ${distance}m 떨어져 있습니다. 외근 등 사유가 있다면 함께 기록해 주세요.` };
  }
  return { latitude, longitude, accuracy: Math.round(accuracy), distance, status: "inside", message: "사업장 반경 안에서 위치가 확인됐습니다." };
}

export function requestCurrentLocation(workplace: Workplace): Promise<LocationResult> {
  if (typeof navigator === "undefined" || !navigator.geolocation) {
    return Promise.resolve({ latitude: null, longitude: null, accuracy: null, distance: null, status: "unavailable", message: "이 기기에서는 위치정보를 확인할 수 없습니다. 사유를 입력해 주세요." });
  }
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => resolve(classifyLocation(coords.latitude, coords.longitude, coords.accuracy, workplace)),
      (error) => resolve({
        latitude: null,
        longitude: null,
        accuracy: null,
        distance: null,
        status: error.code === error.PERMISSION_DENIED ? "permission_denied" : "unavailable",
        message: error.code === error.PERMISSION_DENIED
          ? "위치 권한이 허용되지 않았습니다. 브라우저 설정에서 권한을 허용하거나 사유를 입력해 주세요."
          : "현재 위치를 확인하지 못했습니다. 인터넷과 GPS 상태를 확인한 뒤 다시 시도해 주세요.",
      }),
      { enableHighAccuracy: true, timeout: 15_000, maximumAge: 0 },
    );
  });
}
