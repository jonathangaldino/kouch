# Contributing to Kouch

Thanks for helping. Kouch is a **behavioral port** of TanStack Query: given the same scenario it must behave
the same way. Every change follows from that.

## Ground rules

- **TanStack Query is the specification.** If Kouch and TanStack disagree, Kouch is wrong, unless the
  difference is listed (with its reason) under "Deliberate Swift differences" in the README.
- **Behavior lands with three pieces, in this order:**
  1. a scenario in `Specs/*.md` with a new ID such as `[inv-008]`,
  2. a test with that ID in `Conformance/tanstack/tests/` that passes against real TanStack,
  3. a Swift Testing test with the same ID in `Tests/KouchTests/`.

  When the TanStack test disagrees with what you wrote in the spec, fix the spec. Never edit TanStack's
  behavior to fit.
- **Idiomatic Swift, not translated JavaScript.** Core types are `@MainActor`, query functions are `async`, and
  the code compiles cleanly in Swift 6 language mode with strict concurrency.
- **`Kouch` stays free of UI frameworks.** SwiftUI code belongs in `KouchSwiftUI`.
- **Keep changes small.** One behavior per pull request is easiest to review.

## Setup

Requirements: a Swift 6 toolchain and Node.js 20 or newer. The package is developed and tested with Swift 6.4
(Xcode 27); older Swift 6 compilers have not been verified.

```bash
git clone https://github.com/jonathangaldino/kouch.git
cd kouch
(cd Conformance/tanstack && npm ci)
```

## Checks (CI runs the same)

```bash
(cd Conformance/tanstack && npx vitest run)                                   # TanStack obeys the specs
swift test                                                                    # Kouch obeys the specs
Scripts/check-parity.sh                                                       # same scenario IDs everywhere
xcodebuild -scheme Kouch -destination 'generic/platform=iOS' build
xcodebuild -scheme KouchSwiftUI -destination 'generic/platform=iOS' build
```

## Writing tests

- **TanStack side:** use the helpers in `Conformance/tanstack/tests/helpers.ts`. Time is faked with vitest: use
  `settle()` to let promises run and `advance(ms)` to move time.
- **Swift side:** use `TestEnv` from `Tests/KouchTests/Support/TestSupport.swift`. It provides a virtual
  `TestClock`, its own online and focus managers, and a client. Use `await t.settle()` and `await t.advance(ms)`
  the same way. Prefer the controllable query functions (`Controlled`, `Immediate`, `Failing`) over real delays.
- Assert the numbered "Then" items of the scenario, one by one.

## Upgrading the TanStack version

Bump the exact versions in `Conformance/tanstack/package.json` and run the TanStack suite. Every failure is a
behavior change upstream: update the spec, then make Kouch match, and describe the change in the pull request.

## Pull requests

- Describe the behavior and list the scenario IDs you added or changed.
- By contributing you agree that your contribution is licensed under the MIT License (see `LICENSE`).

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).
