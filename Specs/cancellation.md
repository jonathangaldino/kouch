# Cancellation

Cancelling a fetch rejects it with a `CancelledError` and aborts the query function's signal.
By default (`cancelQueries`) the query **reverts** to the state before the fetch started.

The query function may **consume** its cancellation signal. A consumed signal means "this request is
abortable": when the last observer leaves mid-fetch, the request is aborted. An unconsumed signal
means the request is allowed to finish and populate the cache.

## [cancel-001] Cancel the initial fetch → revert to pending

Given: `fetchQuery(["a"])` in flight (no data).

When: `cancelQueries({queryKey: ["a"]})`.

Then:
1. `status == pending`, `fetchStatus == idle`, `data` undefined, `error == null`.
2. The `fetchQuery` call rejects with a CancelledError.
3. A late resolution of fn does not change state.

## [cancel-002] Cancel a refetch → revert to previous data

Given: `["a"]` with data `"A"`, refetch in flight.

When: `cancelQueries()`.

Then:
1. `status == success`, `data == "A"`, `fetchStatus == idle`.
2. Late resolution `"B"` is ignored; `data == "A"`.

## [cancel-003] Cancel aborts the signal

Given: fn reads its signal; fetch in flight.

When: `cancelQueries()`.

Then:
1. The signal is aborted.

## [cancel-004] Last observer leaves; signal consumed → abort and revert

Given: an observer subscribed to empty `["a"]`, fn reads its signal, fetch in flight.

When: the observer unsubscribes.

Then:
1. The signal is aborted.
2. Query `status == pending`, `fetchStatus == idle`.

## [cancel-005] Last observer leaves; signal not consumed → fetch completes

Given: as cancel-004 but fn does not read its signal.

When: the observer unsubscribes, then fn resolves `"A"`.

Then:
1. `data == "A"`, `status == success`.

## [cancel-006] Cancel without revert results in an error state

Given: `fetchQuery(["a"])` in flight (no data).

When: `query.cancel({revert: false})`.

Then:
1. `status == error`, `fetchStatus == idle`, and `error` is a CancelledError.

## [cancel-007] Cancelling an idle query is a no-op

Given: `["a"]` with data `"A"`, idle.

When: `cancelQueries()`.

Then:
1. State unchanged: `status == success`, `data == "A"`.

## [cancel-008] fetchQuery after cancel starts fresh

Given: cancel-001 happened.

When: `fetchQuery(["a"])` again and fn resolves `"A"`.

Then:
1. Resolves `"A"`; fn calls == 2.
