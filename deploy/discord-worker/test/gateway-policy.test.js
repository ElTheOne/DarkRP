import test from "node:test";
import assert from "node:assert/strict";
import {
  canIdentify,
  gatewayClosePolicy,
  reconnectDelay,
  sessionStartState
} from "../src/gateway-policy.js";

test("fatal Discord configuration errors never reconnect", () => {
  for (const code of [4004, 4010, 4011, 4012, 4013, 4014]) {
    assert.deepEqual(gatewayClosePolicy(code), { fatal: true, resumable: false });
  }
});

test("expired sessions reconnect but do not resume", () => {
  assert.deepEqual(gatewayClosePolicy(4007), { fatal: false, resumable: false });
  assert.deepEqual(gatewayClosePolicy(4009), { fatal: false, resumable: false });
  assert.deepEqual(gatewayClosePolicy(4000), { fatal: false, resumable: true });
});

test("reconnect delay backs off and caps at five minutes", () => {
  assert.equal(reconnectDelay(1, 0), 5000);
  assert.equal(reconnectDelay(2, 0), 10000);
  assert.equal(reconnectDelay(3, 1), 25000);
  assert.equal(reconnectDelay(12, 1), 300000);
});

test("identify is blocked until Discord's reset deadline", () => {
  const state = sessionStartState({ remaining: 0, reset_after: 60000, max_concurrency: 1 }, 1000);
  assert.equal(state.resetAt, 61000);
  const control = { identifyRemaining: 0, identifyResetAt: state.resetAt };
  assert.equal(canIdentify(control, 60999), false);
  assert.equal(canIdentify(control, 61000), true);
});

test("an available identify allowance is immediately usable", () => {
  const state = sessionStartState({ remaining: 5, reset_after: 60000 }, 1000);
  assert.equal(state.resetAt, 61000);
  assert.equal(canIdentify({ identifyRemaining: state.remaining, identifyResetAt: state.resetAt }, 1000), true);
  assert.equal(canIdentify({ identifyRemaining: 0, identifyResetAt: state.resetAt }, 1000), false);
});
