export const FATAL_GATEWAY_CLOSE_CODES = new Set([4004, 4010, 4011, 4012, 4013, 4014]);
export const NON_RESUMABLE_GATEWAY_CLOSE_CODES = new Set([1000, 1001, 4004, 4007, 4009, 4010, 4011, 4012, 4013, 4014]);

export function gatewayClosePolicy(code) {
  const normalized = Number.isInteger(code) ? code : 0;
  return {
    fatal: FATAL_GATEWAY_CLOSE_CODES.has(normalized),
    resumable: !NON_RESUMABLE_GATEWAY_CLOSE_CODES.has(normalized)
  };
}

export function reconnectDelay(attempt, randomUnit = 0) {
  const normalizedAttempt = Math.max(1, Math.min(12, Number.parseInt(attempt, 10) || 1));
  const base = Math.min(300000, 5000 * (2 ** (normalizedAttempt - 1)));
  const jitter = Math.floor(base * 0.25 * Math.max(0, Math.min(1, Number(randomUnit) || 0)));
  return Math.min(300000, base + jitter);
}

export function sessionStartState(sessionStartLimit, now = Date.now()) {
  const remaining = Math.max(0, Number.parseInt(sessionStartLimit?.remaining, 10) || 0);
  const resetAfter = Math.max(0, Number.parseInt(sessionStartLimit?.reset_after, 10) || 0);
  return {
    remaining,
    resetAt: now + resetAfter,
    maxConcurrency: Math.max(1, Number.parseInt(sessionStartLimit?.max_concurrency, 10) || 1)
  };
}

export function canIdentify(control, now = Date.now()) {
  return !control?.identifyResetAt || control.identifyRemaining > 0 || now >= control.identifyResetAt;
}
