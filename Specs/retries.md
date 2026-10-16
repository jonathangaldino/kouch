# Retries

A failed attempt is retried while `retry` allows it. `failureCount` counts failed attempts so far.
Between attempts the retryer waits `retryDelay(failureCount, error)`. If, after waiting, the app is
offline (networkMode `online`) or unfocused, the retryer **pauses** until it can continue.
Resuming requires a mounted client (see network-mode.md).

## [retry-001] Default: 3 retries with exponential backoff

Given: an observer (default retry 3), fn always rejects E.

Then:
1. Attempt 1 at T0; after failure: `failureCount == 1`, `status == pending`, `fetchStatus == fetching`.
2. Attempt 2 at T0 + 1000; attempt 3 at T0 + 3000; attempt 4 at T0 + 7000.
3. After attempt 4: `status == error`, `error == E`, `failureCount == 4`, fn calls == 4.

## [retry-002] retry: false / 0 makes one attempt

Given: observer `retry: false`.

Then:
1. One fn call; `status == error`.

## [retry-003] retry: N

Given: observer `retry: 1`, `retryDelay: 10`.

Then:
1. Exactly 2 fn calls, then error.

## [retry-004] retry function

Given: observer `retry: (failureCount, error) => error.message == "retryable" && failureCount < 2`, `retryDelay: 10`.

When: fn rejects "retryable" every time.
Then:
1. 3 fn calls (failureCount 0 and 1 retried).

When: fn rejects "fatal".
2. 1 fn call.

## [retry-005] retryDelay function receives failureCount

Given: `retry: 2`, `retryDelay: n => (n + 1) * 100`.

Then:
1. Attempts at T0, T0 + 100, T0 + 300.

## [retry-006] Success after retry resets failures

Given: `retry: 3`, `retryDelay: 10`; fn rejects once then resolves `"A"`.

Then:
1. During the delay: `failureCount == 1`, `failureReason == E`.
2. After success: `status == success`, `failureCount == 0`, `failureReason == null`.

## [retry-007] fetchQuery does not retry unless asked

Then:
1. `fetchQuery(["a"])` with failing fn: 1 call.
2. `fetchQuery({queryKey: ["b"], retry: 2, retryDelay: 10})`: 3 calls.

## [retry-008] Retry pauses while offline

Given: client mounted; `retry: 1`, `retryDelay: 1000`, attempt 1 fails at T0, then the network goes offline.

When: advance 1000.
Then:
1. `fetchStatus == paused`, fn calls == 1.

When: network comes back online.
2. `fetchStatus == fetching`, fn calls == 2.

## [retry-009] Retry pauses while unfocused

Given: client mounted; `retry: 1`, `retryDelay: 1000`, attempt 1 fails, then the window loses focus.

When: advance 1000.
Then:
1. `fetchStatus == paused`, fn calls == 1.

When: focus is regained.
2. fn calls == 2.

## [retry-010] Unsubscribing stops further retries (signal not consumed)

Given: observer `retry: 3`, `retryDelay: 1000`, attempt 1 failed, fn does not read the signal.

When: the observer unsubscribes; advance 10 000.

Then:
1. fn calls == 1.
2. Query `status == error`, `fetchStatus == idle`.
