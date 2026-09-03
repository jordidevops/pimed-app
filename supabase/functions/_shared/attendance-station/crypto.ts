export function isValidStationPin(pin: string): boolean {
  return /^\d{4,6}$/.test(pin);
}

export function generateDeviceSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function generateDevicePublicId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `st-${Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

export function generateClientOpId(nowMs: number = Date.now()): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  bytes[0] = (nowMs / 2 ** 40) & 0xff;
  bytes[1] = (nowMs / 2 ** 32) & 0xff;
  bytes[2] = (nowMs / 2 ** 24) & 0xff;
  bytes[3] = (nowMs / 2 ** 16) & 0xff;
  bytes[4] = (nowMs / 2 ** 8) & 0xff;
  bytes[5] = nowMs & 0xff;
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
