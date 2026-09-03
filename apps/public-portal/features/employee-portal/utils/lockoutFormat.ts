export function formatLockoutRemaining(seconds: number): string {
  if (seconds < 60) {
    return seconds <= 1 ? "1 s" : `${seconds} s`;
  }
  const mins = Math.ceil(seconds / 60);
  return mins <= 1 ? "1 min" : `${mins} min`;
}
