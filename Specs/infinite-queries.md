# Infinite Queries

An infinite query stores `InfiniteData = { pages, pageParams }` under one key. The query function
receives a `pageParam` and a `direction`. `getNextPageParam(lastPage, allPages, lastPageParam, allPageParams)`
returns the next param, or nothing when there is no next page. `getPreviousPageParam` works the same way
from the first page.

In these scenarios, page `n` is `"p<n>"` and `getNextPageParam` returns `lastPageParam + 1` while it is below 2,
otherwise nothing (3 pages: params 0, 1, 2). `initialPageParam` is 0.

## [inf-001] Initial fetch loads the first page

When: an infinite observer for `["list"]` subscribes and the fetch resolves `"p0"`.

Then:
1. fn called once with `pageParam == 0`, `direction == forward`.
2. `data == {pages: ["p0"], pageParams: [0]}`.
3. `hasNextPage == true`, `hasPreviousPage == false` (no `getPreviousPageParam`).

## [inf-002] fetchNextPage appends the next page

Given: inf-001 resolved.

When: `fetchNextPage()`.
Then:
1. While in flight: `isFetchingNextPage == true`, `isRefetching == false`, `isFetching == true`.
2. fn called with `pageParam == 1`, `direction == forward`.

When: it resolves `"p1"`.
3. `data.pages == ["p0", "p1"]`, `data.pageParams == [0, 1]`, `isFetchingNextPage == false`.

## [inf-003] No next page

Given: pages `p0, p1, p2` loaded.

Then:
1. `hasNextPage == false`.

When: `fetchNextPage()` and the fetch settles.
2. fn not called again; `data.pages == ["p0", "p1", "p2"]`.

## [inf-004] fetchPreviousPage prepends

Given: `initialPageParam: 5`, `getPreviousPageParam: (first, all, firstParam) => firstParam - 1`, first page loaded.

Then:
1. `hasPreviousPage == true`.

When: `fetchPreviousPage()`.
2. While in flight: `isFetchingPreviousPage == true`; fn called with `pageParam == 4`, `direction == backward`.

When: it resolves `"p4"`.
3. `data.pages == ["p4", "p5"]`, `data.pageParams == [4, 5]`.

## [inf-005] Refetch reloads every page in order

Given: pages `p0, p1` loaded (fn returns `"p<n>-v<call>"` style values on refetch).

When: `refetch()`.

Then:
1. fn called with `pageParam` 0 then 1 (sequentially: page 1 is requested only after page 0 resolves).
2. `data.pages` holds the two new pages; `data.pageParams == [0, 1]`.

## [inf-006] Refetch stops when there is no next page anymore

Given: pages for params 0, 1, 2 loaded; then `getNextPageParam` changes behavior so that the refetched
page 0 reports no next page.

When: `refetch()`.

Then:
1. fn called once (param 0).
2. `data.pages.length == 1`.

## [inf-007] maxPages

Given: `maxPages: 2`.

When: pages for params 0, 1, 2 are fetched in sequence (`fetchNextPage` twice).

Then:
1. `data.pageParams == [1, 2]`, `data.pages == ["p1", "p2"]`.

## [inf-008] fetchNextPage error

Given: page `p0` loaded, `retry: false`.

When: `fetchNextPage()` rejects E.

Then:
1. `status == error`, `isFetchNextPageError == true`, `isRefetchError == false`.
2. `data.pages == ["p0"]` (kept).

## [inf-009] fetchInfiniteQuery with pages

When: `fetchInfiniteQuery({queryKey: ["list"], pages: 3, ...})` with fn resolving immediately.

Then:
1. Resolves with `pageParams == [0, 1, 2]`.
2. fn called 3 times.

## [inf-010] fetchNextPage joins an in-flight fetch with cancelRefetch: false

Given: page `p0` loaded, `fetchNextPage()` in flight.

When: `fetchNextPage({cancelRefetch: false})`.

Then:
1. fn called once for both calls.
