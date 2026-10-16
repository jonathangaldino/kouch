# Acknowledgements

## TanStack Query

SwiftQuery would not exist without [TanStack Query](https://tanstack.com/query) by
[Tanner Linsley](https://github.com/tannerlinsley) and the
[TanStack contributors](https://github.com/TanStack/query/graphs/contributors).

TanStack Query changed how a generation of apps think about server state: caching, deduplication,
stale-while-revalidate, garbage collection, retries, invalidation and persistence, all behind a small, honest
API. Years of careful design, edge-case handling and an extraordinary test suite went into it. SwiftQuery stands
entirely on that work.

SwiftQuery is a **behavioral port**. TanStack Query's code was not translated or copied. Its behavior is the
specification:

- `Specs/` describes TanStack Query's behavior in Given/When/Then scenarios.
- `Conformance/tanstack/` runs each scenario against the published npm packages `@tanstack/query-core`,
  `@tanstack/query-persist-client-core` and `@tanstack/query-async-storage-persister` (installed as
  development dependencies, not redistributed).
- The Swift implementation must pass the same scenarios.

TanStack Query's API names, option names and documented semantics are reused deliberately, so knowledge carries
over between the two. Any mistakes in SwiftQuery are ours, not theirs.

If SwiftQuery helps you, please consider [sponsoring TanStack](https://github.com/sponsors/tannerlinsley) and
giving [TanStack Query](https://github.com/TanStack/query) a star.

TanStack Query is distributed under the following license:

```
MIT License

Copyright (c) 2021-present Tanner Linsley

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Contributor Covenant

`CODE_OF_CONDUCT.md` is the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1.
