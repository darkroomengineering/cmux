# Provenance

Vendored from the upstream `cmux` fork. Not a submodule, not a live SPM
dependency — a one-time source copy, following the `vendor/bonsplit` precedent.

| | |
|---|---|
| Source repo | `upstream` remote (cmux) |
| Source path | `Packages/Shared/CMUXMobileCore` |
| Commit | `34cc2ba5110adf45c27607e865be5867fbcad8a9` (`upstream/main`) |
| Extracted | 2026-07-27 |

Re-extract with:

```sh
git archive 34cc2ba5110adf45c27607e865be5867fbcad8a9 Packages/Shared/CMUXMobileCore \
  | tar -x --strip-components=3 -C vendor/CMUXMobileCore
```

There is no live tracking of upstream after this point. See
`plans/golden-tumbling-gray.md` for why (4,706-commit divergence, and upstream
commits risk reintroducing the account/broker coupling this port deliberately removes).
