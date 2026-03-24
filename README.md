# ci-actions

Reusable GitHub Actions composite actions for the butterflyskies org, built
with supply chain security as a first-class concern.

## Actions

### `setup-rust`

Checkout → system deps → Rust toolchain → cargo cache → optional tool installs.

```yaml
- uses: butterflyskies/ci-actions/setup-rust@<sha>
  with:
    toolchain: stable          # or "1.88", "nightly", etc.
    components: clippy,rustfmt # optional
    cache-key: msrv            # optional, differentiates cache entries
    cargo-tools: >-            # optional, space-separated name@version
      cargo-nextest@0.9.131
      cargo-auditable@0.7.4
```

### `docker-publish`

Docker Buildx → GHCR login → metadata → build + push with provenance, SBOM,
and GHA layer caching.

```yaml
- uses: butterflyskies/ci-actions/docker-publish@<sha>
  with:
    image: butterflyskies/memory-mcp
    registry-username: ${{ github.actor }}
    registry-password: ${{ secrets.GITHUB_TOKEN }}
    push: ${{ github.event_name != 'pull_request' }}
    tag-rules: |
      type=semver,pattern={{version}},value=${{ inputs.tag }}
      type=semver,pattern={{major}}.{{minor}},value=${{ inputs.tag }}
```

## Supply chain security model

This repo addresses several of the concerns from [Dan Lorenc's post on Actions
security][lorenc]:

### What we do

| Concern | Mitigation |
|---|---|
| **Mutable tags** | Every `uses:` reference is pinned to a full 40-char commit SHA, never a tag. |
| **Transitive dependencies** | `DEPS.lock` records the git tree hash for every pinned commit. CI verifies these on every push and weekly on a schedule. |
| **`GITHUB_TOKEN` scope** | Composite actions declare no permissions; callers must grant exactly what's needed per-job. |
| **`pull_request_target`** | Not used anywhere. |
| **Template injection** | No `${{ }}` interpolation in shell `run:` blocks — all values pass through `inputs` which GitHub sanitizes. |

### What we can't fix from here

- **No real publish gate**: GitHub still treats any public repo as an action.
  We mitigate by always pinning to SHAs, but there's no registry-level
  verification.
- **No immutable tags with transparency log**: Git tags remain mutable.
  `DEPS.lock` is our approximation — it makes rewrites detectable, not
  impossible. A proper solution needs Sigstore integration at the platform
  level.

### Updating dependencies

1. Update the SHA in the relevant `action.yml`
2. Run `./scripts/lock-deps.sh` to regenerate `DEPS.lock`
3. CI will verify the new hashes; review the diff carefully
4. Both files must change in the same commit — the lint job enforces this

## Versioning

This repo uses semver tags. Consumers should pin to a commit SHA (not a tag)
for the same reasons we pin our own dependencies. Tags exist for human
readability and changelogs.

[lorenc]: https://daniellorenc.com/posts/2025-actions/
