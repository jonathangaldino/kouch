# Security Policy

## Supported versions

Kouch is pre-1.0. Security fixes go into the latest release only.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report them privately through GitHub's
[private vulnerability reporting](https://github.com/jonathangaldino/kouch/security/advisories/new) for this repository.
Include what you found, how to reproduce it, and the impact you expect.

You can expect an acknowledgement within a few days. We will keep you updated while we investigate, and credit you
in the advisory unless you prefer otherwise.

Areas that deserve particular care:

- **Persistence.** `StoragePersister` and `FileQueryStorage` write cached query data to disk unencrypted. Don't
  persist secrets, or provide a `QueryStorage` that encrypts.
- **Hydration.** Snapshots are decoded into the types your app reads. Treat snapshots from outside your app's own
  storage as untrusted input.
