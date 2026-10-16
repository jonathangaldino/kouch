# Mutations

A mutation performs a side effect. Unlike queries, mutations are not deduplicated or cached by
key: every `mutate` call creates a new Mutation in the mutation cache.

State: `status` (`idle | pending | success | error`), `data`, `error`, `variables`, `context`,
`failureCount`, `failureReason`, `isPaused`, `submittedAt`.

## [mut-001] Observer starts idle

Then:
1. A new MutationObserver result: `status == idle`, `isIdle`, `data`/`variables` undefined.

## [mut-002] Successful mutate

Given: a subscribed observer; time T0.

When: `mutate("vars")`.
Then:
1. Result `status == pending`, `variables == "vars"`, `submittedAt == T0`.

When: mutationFn resolves `"done"`.
2. Result `status == success`, `data == "done"`; `mutate` resolves `"done"`.
3. mutationFn received `"vars"`.

## [mut-003] Callback order on success

Given: mutation cache config `onMutate/onSuccess/onSettled`, mutation options
`onMutate (returns "ctx") / onSuccess / onSettled`, and mutate options `onSuccess / onSettled`.

When: `mutate("v")` succeeds with `"d"`.

Then the recorded order is:
1. `cache.onMutate`, `onMutate`, `mutationFn`, `cache.onSuccess`, `onSuccess`, `cache.onSettled`,
   `onSettled`, `mutate.onSuccess`, `mutate.onSettled`.
2. `onSuccess` received (`"d"`, `"v"`, `"ctx"`).
3. Result `context == "ctx"`.

## [mut-004] Error

When: mutationFn rejects E.

Then:
1. Order: `cache.onError`, `onError`, `cache.onSettled`, `onSettled`, `mutate.onError`, `mutate.onSettled`.
2. `status == error`, `error == E`, `failureCount == 1`, `data` undefined.
3. `mutate` rejects with E.

## [mut-005] Retries are off by default

Then:
1. Failing mutationFn called once.
2. With `retry: 2, retryDelay: 10`: called 3 times.

## [mut-006] Offline mutations pause and resume

Given: client mounted; network offline.

When: `mutate("v")`.
Then:
1. `status == pending`, `isPaused == true`, mutationFn not called.

When: network online.
2. mutationFn called; then `status == success`, `isPaused == false`.

## [mut-007] Same scope runs serially

Given: two observers with `scope: {id: "s"}`.

When: `mutate` on both.

Then:
1. Second is `pending` with `isPaused == true`; only the first mutationFn called.
2. After the first resolves, the second mutationFn is called.

Without scope: both mutationFns are called immediately.

## [mut-008] Mutation garbage collection

Given: a mutation with `gcTime: 1000` succeeds while its observer is subscribed.

When: the observer unsubscribes at T1.

Then:
1. At T1 + 999 the mutation cache has 1 mutation; at T1 + 1000 it has 0.

## [mut-009] reset

Given: an observer after a successful mutation.

When: `reset()`.

Then:
1. Result back to `status == idle`, data undefined.

## [mut-010] Invalidate from onSuccess

Given: an active query `["todos"]` and a mutation whose `onSuccess` calls `invalidateQueries({queryKey: ["todos"]})`.

When: the mutation succeeds.

Then:
1. The todos query refetched.

## [mut-011] isMutating

When: two mutations are pending.

Then:
1. `isMutating() == 2`; after both settle `isMutating() == 0`.
