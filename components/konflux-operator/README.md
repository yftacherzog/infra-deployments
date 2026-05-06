# Konflux Operator Component

This component deploys the Konflux operator from the upstream release install bundle.

Current source:

- <https://github.com/konflux-ci/konflux-ci/releases/tag/v0.1.12>
- <https://github.com/konflux-ci/konflux-ci/releases/download/v0.1.12/install.yaml>

Notes:

- The bundle is consumed as raw manifests (not OLM objects).
- `development/` now contains an env-local promotable bundle:
  - `development/upstream/` pins operator source + image tag for that ring.
  - `development/cr/release-config.yaml` holds release-variant CR config.
  - `development/cr/overlay-patches/` holds overlay/team-owned CR patches.
- For version bumps in the active ring, update `development/upstream/kustomization.yaml`.


Konflux CR composition and ownership

- `development/cr/base/` contains a minimal single `Konflux` CR.
- `development/cr/release-config.yaml` is the release-level CR layer that should move between rings during promotion.
- `development/cr/overlay-patches/*` directories (for example `build`, `integration`, `release`, `konflux-ui`, `namespace-lister`, `konflux-info`, `image-controller`) contain stable overlay/team-owned patches and per-team `OWNERS` files.
- Patch style is intentionally simple (`patchesStrategicMerge`) for now; this can be switched later if list-level merges become hard to manage.
