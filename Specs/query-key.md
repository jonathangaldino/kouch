# Query Key

A query key is an array of JSON-like values (strings, numbers, booleans, null, arrays, objects).
It is the **identity** of a query in the cache.

## [key-001] Object key order does not affect identity

Given: an empty cache.

When: a query is built with key `["todos", {status: "done", page: 1}]`
And: a query is built with key `["todos", {page: 1, status: "done"}]`

Then:
1. Both builds return the same Query instance.
2. The cache contains exactly one query.

## [key-002] Different keys are different queries

When: queries are built for `["user", 1]` and `["user", 2]`.

Then:
1. They are different Query instances.
2. The cache contains two queries.

## [key-003] Array element order matters

When: queries are built for `["a", 1, 2]` and `["a", 2, 1]`.

Then:
1. They are different queries.

## [key-004] Prefix filter matches by leading elements

Given: queries `["todos"]`, `["todos", 1]`, `["todos", {done: true}]`, `["todo"]`, `["posts"]`.

When: `findAll({queryKey: ["todos"]})`.

Then:
1. Exactly `["todos"]`, `["todos", 1]`, `["todos", {done: true}]` match (3 queries).

## [key-005] Object filter element matches by subset

Given: queries `["todos", {status: "done", page: 1}]`, `["todos", {status: "open", page: 1}]`.

When: `findAll({queryKey: ["todos", {status: "done"}]})`.

Then:
1. Only `["todos", {status: "done", page: 1}]` matches.

## [key-006] Exact filter matches only the identical key

Given: queries `["todos"]`, `["todos", 1]`.

When: `findAll({queryKey: ["todos"], exact: true})`.

Then:
1. Only `["todos"]` matches.
