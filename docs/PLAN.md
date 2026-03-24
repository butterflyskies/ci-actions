# ci-actions: Rust CLI + Supply Chain Hardening

> This document is the canonical plan for the ci-actions project. It is committed
> to the repo and evolves over time. Changes to this plan should be reviewed like
> code — the evolution of the plan is part of the project record.

## PR Structure

| PR | Contents | Depends On |
|----|----------|-----------|
| **PR #1** (this plan) | This document committed to `docs/PLAN.md` | — |
| **PR #2** (core implementation) | Phases 1–7, 9: Rust CLI, bootstrap, CI hardening, Dependabot, CODEOWNERS, attestation, TUF stubs, documentation, final lock | PR #1 |
| **PR #3** (consumer artifacts) | Phase 8: release binary, verify-deps action, scaffold command, reusable workflow | PR #2 |

## Context

The repo is a first draft from claude.ai containing reusable GitHub Actions (`setup-rust`, `docker-publish`) with shell-based dependency verification. We're upgrading it to a proper Rust project with comprehensive supply chain security, automated dependency management, and documentation of what can and can't be verified today.

The audit of `dtolnay/rust-toolchain` revealed no integrity verification of rustup downloads (curl | sh with no checksum) and minor shell quoting issues. We're replacing it with our own rustup bootstrap in `setup-rust` with SHA256 verification of the rustup installer and pinned rustup version. This improves verifiability — we can audit and test every line of our own bootstrap code.

## Phase 1: Rust Project Scaffolding

Create `Cargo.toml`, `rust-toolchain.toml`, update `.gitignore`.

```toml
[package]
name = "ci-actions-verify"
version = "0.1.0"
edition = "2024"
license = "MIT OR Apache-2.0"

[[bin]]
name = "ci-actions-verify"
path = "src/verify_main.rs"

[[bin]]
name = "ci-actions-bootstrap"
path = "src/bootstrap_main.rs"

[dependencies]
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_yml = "0.0.12"
regex = "1"
anyhow = "1"
sha2 = "0.10"
hex = "0.4"
glob = "0.3"

[features]
default = []
sigstore = ["dep:sigstore"]

[dependencies.sigstore]
version = "0.13"
optional = true

[dev-dependencies]
tempfile = "3"
assert_cmd = "2"
predicates = "3"
```

Two binaries:
- **`ci-actions-verify`**: deps lock/verify/scan tool (used in CI)
- **`ci-actions-bootstrap`**: rustup installer with integrity verification (used by `setup-rust` action)

Decision: shell out to `git` CLI for shallow fetch (proven pattern from existing scripts, `gix` doesn't handle GitHub's fetch-by-arbitrary-SHA well). Keep it simple — no `gix`/`octocrab` for now.

### sigstore feature flag

`sigstore-rs` v0.13.0 can do useful things today: query Rekor transparency log, verify cosign container image signatures, verify blob signatures. It **cannot** verify GitHub artifact attestation bundles (issue #393), gitsign commit signatures, or SLSA provenance. We add it as an optional feature for advisory Rekor transparency checks — not load-bearing, but surfaces additional information when available. Tree-hash verification remains the gate.

## Phase 2: Rust CLI Implementation

**`src/verify_main.rs`** — clap derive CLI with three subcommands: `lock`, `verify`, `scan`

**`src/deps_lock.rs`** — DEPS.lock parser/writer
- Preserves comments and blank lines for round-trip fidelity
- Strict line validation: `^[a-zA-Z0-9_/-]+@[0-9a-f]{40} [0-9a-f]{40}$`
- Rejects malformed lines with clear errors

**`src/actions_yaml.rs`** — GitHub Actions YAML parser
- Uses `serde_yml::Value` (not strongly-typed structs — workflow YAML is too polymorphic)
- Walks the Value tree looking for `uses` keys
- Handles both workflow files (`jobs.<job>.steps[].uses`) and composite actions (`runs.steps[].uses`)
- Returns `Vec<ActionRef>` with file path, action, ref, line number
- Warns on dynamic `uses:` containing `${{ }}` (can't be statically verified)

**`src/git.rs`** — Git operations
- `fetch_tree_hash(action, commit_sha) -> Result<String>`: tmpdir, `git init`, `git fetch --depth 1`, `git rev-parse SHA^{tree}`
- Temp directory pool to avoid re-cloning same repo in one run

**`src/lock.rs`** — `lock` command: parse DEPS.lock, fetch tree hashes, update in place
**`src/verify.rs`** — `verify` command: parse DEPS.lock, fetch tree hashes, compare, emit `::error::` annotations
**`src/scan.rs`** — `scan` command: glob for `**/*.yml` + `**/*.yaml`, extract `uses:` refs, check SHA-pinned, check present in DEPS.lock

## Phase 2.5: Rustup Bootstrap Binary (`ci-actions-bootstrap`)

Replace `dtolnay/rust-toolchain` with our own toolchain setup with integrity verification.

**`src/bootstrap_main.rs`** — clap derive CLI:
```
ci-actions-bootstrap --toolchain stable --targets x86_64-unknown-linux-gnu --components clippy,rustfmt
```

**`src/rustup.rs`** — Rustup installer with verification:
- Downloads rustup-init from `https://static.rust-lang.org/rustup/archive/{version}/{target}/rustup-init`
  (pinned version, not `sh.rustup.rs` which always gives latest)
- Verifies SHA256 against a known-good hash hardcoded in `src/rustup_hashes.rs`
- Makes it executable, runs it with `--default-toolchain none -y`
- Then runs `rustup toolchain install {toolchain}` with targets/components
- Sets `rustup default {toolchain}`
- Writes cargo env vars to `$GITHUB_ENV`: `CARGO_INCREMENTAL=0`, `CARGO_TERM_COLOR=always`, `CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse`

**`src/rustup_hashes.rs`** — Known-good SHA256 hashes for pinned rustup version.

Hashes were fetched from `static.rust-lang.org/rustup/archive/1.29.0/{target}/rustup-init.sha256` on 2026-03-24 and independently verified by downloading the binary and computing `sha256sum` locally. These are hardcoded — not fetched at runtime — because fetching at runtime trusts the CDN at verification time (same MITM surface we're closing).

```rust
pub const RUSTUP_VERSION: &str = "1.29.0";
pub const RUSTUP_HASHES: &[(&str, &str)] = &[
    // Linux (glibc)
    ("x86_64-unknown-linux-gnu",    "4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10"),
    ("aarch64-unknown-linux-gnu",   "9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792"),
    ("i686-unknown-linux-gnu",      "5140e82096f96d1d8077f00eb312648e0e5106d101c9918d086f72cbc69bb3a1"),
    // Linux (musl)
    ("x86_64-unknown-linux-musl",   "9cd3fda5fd293890e36ab271af6a786ee22084b5f6c2b83fd8323cec6f0992c1"),
    ("aarch64-unknown-linux-musl",  "88761caacddb92cd79b0b1f939f3990ba1997d701a38b3e8dd6746a562f2a759"),
    // macOS
    ("x86_64-apple-darwin",         "33cf85df9142bc6d29cbc62fa5ca1d4c29622cddb55213a4c1a43c457fb9b2d7"),
    ("aarch64-apple-darwin",        "aeb4105778ca1bd3c6b0e75768f581c656633cd51368fa61289b6a71696ac7e1"),
    // Windows (MSVC)
    ("x86_64-pc-windows-msvc",      "86478e53f769379d7f0ebfa7c9aa97cb76ca92233f79aa2cc0dbee2efaac73c7"),
    ("aarch64-pc-windows-msvc",     "3af309e6c3062aa11df0e932954f69d13b734d8a431e593812f3ecd9ff9e6ef6"),
    ("i686-pc-windows-msvc",        "f574ea2bd6d798b6072b3a45e3053f3cabcc2cb48d6b4bd59b661b41d675b31a"),
    // Windows (GNU)
    ("x86_64-pc-windows-gnu",       "03dbaae1d33a4d220bd0d202e5092955dae859c119074192ca513f8c4713fff7"),
];
```

All 11 hashes verified on 2026-03-24 by: (1) fetching from archive URL, (2) computing sha256sum locally, (3) comparing against upstream `.sha256` files. All three sources agreed.

Upstream verification chain: SHA256 checksums published by the Rust project alongside binaries. GPG signatures exist for channel manifests but not for individual rustup-init binaries. The Rust project is migrating to TUF (The Update Framework, RFC #3724) but it's not yet implemented. Our hardcoded hashes are the strongest verification available today.

To update: run `ci-actions-verify rustup-pin <version>` (see below).

### Rustup Pin Command

The process we used to determine the hashes (fetch from archive, download binary, sha256sum locally, compare against upstream `.sha256` file) must be codified as a CLI subcommand so it's repeatable, auditable, and not dependent on a human running ad-hoc curl commands.

**New subcommand**: `ci-actions-verify rustup-pin <version>`

Behavior:
1. For each target triple in a hardcoded list of supported targets:
   a. Fetch `https://static.rust-lang.org/rustup/archive/{version}/{target}/rustup-init[.exe].sha256` (upstream published hash)
   b. Download `https://static.rust-lang.org/rustup/archive/{version}/{target}/rustup-init[.exe]` (the actual binary)
   c. Compute SHA256 of the downloaded binary locally
   d. Compare local hash against upstream `.sha256` file — if they disagree, abort with error (CDN inconsistency or MITM)
   e. Record the verified hash
2. Output a new `rustup_hashes.rs` file content to stdout (or write to `src/rustup_hashes.rs` with `--write`)
3. Also output a machine-readable `rustup-hashes.json` for TUF targets signing
4. Print a verification report to stderr showing each target, both hash sources, and pass/fail

This means the update workflow is:
```
ci-actions-verify rustup-pin 1.30.0 --write
cargo fmt
cargo test  # invariant 58 checks all hashes are 64 hex chars
git diff src/rustup_hashes.rs  # review the change
git commit
```

**`src/rustup_pin.rs`** — implementation module

**Invariants (rustup-pin)**:

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 74 | Aborts if upstream `.sha256` and local sha256sum disagree | CDN inconsistency or MITM — if the two sources disagree, something is wrong and we must not proceed | P2, P7 | Integration (mock server) |
| 75 | Aborts if any target download fails | Partial pin updates leave some targets unverified; must be all-or-nothing | P2, P7 | Integration (mock server) |
| 76 | Generated `rustup_hashes.rs` compiles and passes invariant 58 | The output must be syntactically valid Rust with correctly formatted hashes | P6 | Integration |
| 77 | Generated `rustup-hashes.json` is valid JSON with all targets | Machine-readable output for TUF signing must be well-formed | P5 | Integration |
| 78 | All supported target triples are covered (no silent omission) | A missing target means that platform gets no verification | P2 | Unit |
| 79 | Uses HTTPS-only with TLS 1.2+ for all downloads | Network security baseline — same as rustup's own curl flags | P2 | Unit (URL construction) |
| 80 | Windows targets use `.exe` suffix in download URL | Wrong URL = wrong binary or 404 | P6 | Unit |

**Update `setup-rust/action.yml`**:
- Remove `dtolnay/rust-toolchain` step entirely
- Remove it from DEPS.lock (one fewer upstream dependency)
- For the initial PR: use a shell-based verified rustup install (the Rust binary becomes the path once we have releases)
- All inputs pass through `env:` (no `${{ }}` in `run:`), proper quoting throughout

**Shell fallback for bootstrap** (in `setup-rust/action.yml`, temporary until binary releases):
```yaml
- name: Install rustup (verified)
  shell: bash
  env:
    RUSTUP_VERSION: "1.29.0"
    # Hashes for all supported targets — shell detects runner arch and selects
    RUSTUP_HASHES: |
      x86_64-unknown-linux-gnu:4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
      aarch64-unknown-linux-gnu:9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
      x86_64-apple-darwin:33cf85df9142bc6d29cbc62fa5ca1d4c29622cddb55213a4c1a43c457fb9b2d7
      aarch64-apple-darwin:aeb4105778ca1bd3c6b0e75768f581c656633cd51368fa61289b6a71696ac7e1
      x86_64-pc-windows-msvc:86478e53f769379d7f0ebfa7c9aa97cb76ca92233f79aa2cc0dbee2efaac73c7
    TOOLCHAIN: ${{ inputs.toolchain }}
    TARGETS: ${{ inputs.targets }}
    COMPONENTS: ${{ inputs.components }}
  run: |
    set -euo pipefail
    # Detect target triple from runner OS and architecture
    arch=$(uname -m)
    os=$(uname -s)
    case "${os}-${arch}" in
      Linux-x86_64)   target="x86_64-unknown-linux-gnu" ;;
      Linux-aarch64)   target="aarch64-unknown-linux-gnu" ;;
      Darwin-x86_64)   target="x86_64-apple-darwin" ;;
      Darwin-arm64)    target="aarch64-apple-darwin" ;;
      MINGW*|MSYS*)    target="x86_64-pc-windows-msvc" ;;
      *) echo "::error::Unsupported platform: ${os}-${arch}"; exit 1 ;;
    esac
    # Look up the expected hash for this target
    expected_hash=$(echo "$RUSTUP_HASHES" | grep "^${target}:" | cut -d: -f2)
    if [ -z "$expected_hash" ]; then
      echo "::error::No known hash for target ${target}"; exit 1
    fi
    suffix=""; [[ "$target" == *windows* ]] && suffix=".exe"
    url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init${suffix}"
    curl --proto '=https' --tlsv1.2 -fsSL -o rustup-init "$url"
    echo "${expected_hash}  rustup-init" | sha256sum -c -
    chmod +x rustup-init
    ./rustup-init --default-toolchain none -y
    source "$HOME/.cargo/env"
    rustup toolchain install "$TOOLCHAIN" --profile minimal
    IFS=',' read -ra tgts <<< "$TARGETS"
    for t in "${tgts[@]}"; do [ -n "$t" ] && rustup target add --toolchain "$TOOLCHAIN" "$t"; done
    IFS=',' read -ra comps <<< "$COMPONENTS"
    for c in "${comps[@]}"; do [ -n "$c" ] && rustup component add --toolchain "$TOOLCHAIN" "$c"; done
    rustup default "$TOOLCHAIN"
    echo "CARGO_INCREMENTAL=0" >> "$GITHUB_ENV"
    echo "CARGO_TERM_COLOR=always" >> "$GITHUB_ENV"
    echo "CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse" >> "$GITHUB_ENV"
```

## Phase 3: CI Hardening

Rewrite `.github/workflows/ci.yml`:

- Pin all jobs to `ubuntu-24.04`
- This repo's own CI uses the constituent actions directly (checkout + rust-cache) plus our own rustup bootstrap. No self-referential `setup-rust` usage — avoids the bootstrap chicken-and-egg.
- Jobs:
  - `fmt-clippy`: cargo fmt --check, cargo clippy -- -D warnings
  - `test`: cargo nextest run
  - `verify-deps`: build CLI, run `ci-actions-verify verify` and `ci-actions-verify scan`
  - `verify-deps-fallback`: keep shell scripts as fallback (run in parallel, compare results)
- Weekly cron stays for tag rewrite detection
- Pin system deps in setup-rust: `libdbus-1-dev=1.14.10-4ubuntu4.1 pkg-config=1.8.1-2build1` (soft pin — CI will fail visibly if the runner image changes these, which is the signal we want)

## Phase 4: Dependabot + CODEOWNERS

**`.github/dependabot.yml`**: Weekly updates for `github-actions` ecosystem (directories: `/`, `/setup-rust`, `/docker-publish`) + `cargo` ecosystem.

**`.github/CODEOWNERS`**: `@butterflysky` as owner for `*/action.yml`, `DEPS.lock`, `.github/workflows/`, `Cargo.toml`, `Cargo.lock`.

## Phase 5: Attestation Support

Add to `docker-publish/action.yml`:
- New `attestation` input (default `"true"`)
- `actions/attest-build-provenance` step after build-push, gated on `inputs.push == 'true' && inputs.attestation == 'true'`
- Requires callers to grant `id-token: write` and `attestations: write` — document this
- Add `id: build` to the build-push step to capture digest output
- Pin the new action SHA and add to DEPS.lock

## Phase 6: Documentation

**`SUPPLY_CHAIN.md`** — New file documenting verification status of each upstream dep:

| Action | Signed Commits | Produces Attestations | Our Verification |
|--------|---------------|----------------------|-----------------|
| actions/checkout | GitHub bot (GPG) | N/A | Tree hash |
| Swatinem/rust-cache | GPG | No | Tree hash |
| docker/setup-buildx-action | Standard | No | Tree hash |
| docker/login-action | Standard | No | Tree hash |
| docker/metadata-action | Standard | No | Tree hash |
| docker/build-push-action | Standard | SLSA provenance for images | Tree hash + provenance |
| actions/attest-build-provenance | GitHub bot (GPG) | N/A (it generates them) | Tree hash |
| rustup-init binary | N/A | N/A | SHA256 checksum (pinned version) |

`dtolnay/rust-toolchain` removed — replaced with our own rustup bootstrap with SHA256-verified downloads and no shell injection surface. Improved verifiability: every line of bootstrap code is ours to audit and test.

"What we can't do yet" section:
- No upstream actions use gitsign/sigstore for commit signing
- GitHub UI doesn't recognize Sigstore signatures as "verified" (different CA root)
- `sigstore-rs` v0.13.0 can query Rekor and verify cosign signatures, but cannot verify GitHub artifact attestation bundles (issue #393) or gitsign commit signatures
- We use sigstore behind a feature flag for advisory Rekor transparency checks; tree-hash verification remains the gate
- Future: when sigstore-rs gains v0.3 bundle verification, promote to load-bearing

**Update `README.md`**: CLI usage, security model update, dependency update workflow (Dependabot PR -> update SHA -> `ci-actions-verify lock` -> review diff -> merge).

**Update `SECURITY.md`**: Expanded threat model with attestation section.

## Phase 7: TUF Integration

Adopt The Update Framework to provide a formal trust root for consumers of ci-actions.

### Why TUF

DEPS.lock + tree-hash verification proves content hasn't changed. TUF adds:
- **Key rotation**: If a signing key is compromised, we can revoke it without breaking consumers
- **Threshold signing**: M-of-N signatures required — no single key compromise can poison the chain
- **Rollback protection**: Consumers can detect if they're being served stale metadata
- **Consumer verification**: Downstream repos can cryptographically verify our dependency pins without trusting GitHub's transport layer

### Implementation

**Crate**: `tough` (AWS Labs, v0.21.0+, production-ready, 1.1M+ downloads). Note: delegations not yet supported in tough — all targets signed by one role for now.

**Tooling**: `tuf-on-ci` (official TUF project) for managing the TUF repo lifecycle via GitHub Actions.

**Repository**: Create `tuf/` directory in this repo (or separate `ci-actions-tuf` repo — decide during implementation). Publish metadata to GitHub Pages.

**What we sign as TUF targets**:
- `DEPS.lock` (action dependency pins + tree hashes)
- `rustup-hashes.json` (exported from `rustup_hashes.rs` for machine consumption)
- `security-controls.json` (so consumers can verify our controls metadata hasn't been tampered with)

**Role structure** (MVP):
- **Root**: 1 offline key (single maintainer reality — upgrade to threshold when more contributors join)
- **Targets**: 1 online key (stored in GitHub Secrets, used by CI to sign on release)
- **Snapshot + Timestamp**: 1 online key (same as targets for MVP, can separate later)

**Add to Cargo.toml**:
```toml
[dependencies.tough]
version = "0.21"
optional = true

[features]
default = []
sigstore = ["dep:sigstore"]
tuf = ["dep:tough"]
```

**New CLI subcommand**: `ci-actions-verify tuf-sign` (signs targets metadata) and `ci-actions-verify tuf-verify` (consumer-facing verification against the TUF repo).

**Phase 7 is scaffolding only in this PR**: Create the `tuf/` directory structure, add `tough` as optional dep, implement the `tuf-sign` and `tuf-verify` subcommand stubs with `todo!()` bodies, and document the roadmap in `SECURITY_CONTROLS.md`. Full TUF ceremony and metadata publishing is a follow-up PR — it requires offline key generation which is a separate process.

### Invariants (TUF)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 71 | `tough` crate compiles with `tuf` feature flag | Build verification — the dependency is usable | Correctness | Unit (build) |
| 72 | `tuf-sign` subcommand is registered and prints help | CLI integration — the command exists | Correctness | Integration |
| 73 | `tuf-verify` subcommand is registered and prints help | CLI integration — the command exists | Correctness | Integration |

(Full TUF invariants — metadata freshness, rollback detection, threshold enforcement — will be added when the implementation lands.)

## Phase 8: Consumer-Facing Artifacts (separate PR)

All four artifacts below enable consumer projects to adopt the same supply chain practices we use. This phase is a separate PR from the core implementation.

### 8a. Release Binary

Publish `ci-actions-verify` as a GitHub release artifact (per-platform, SHA256-checksummed). Consumer projects download it in their CI and run it against their own repos.

- **Build matrix**: linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64, windows-x86_64
- **Release workflow**: trigger on version tags, build with `cargo-auditable`, upload with checksums
- **Consumers pin**: download URL + SHA256 hash in their workflow (same pattern we use for rustup)
- **Attestation**: use `actions/attest-build-provenance` on the release binaries (dogfooding our own docker-publish pattern)

### 8b. `verify-deps` Composite Action

New action at `butterflyskies/ci-actions/verify-deps/action.yml`. Zero-config for consumers:

```yaml
# In a consumer's workflow:
- uses: butterflyskies/ci-actions/verify-deps@<sha>
```

Internally:
1. Downloads the pinned `ci-actions-verify` binary from our GitHub release (SHA256-verified)
2. Runs `ci-actions-verify scan` against the consumer's repo
3. Optionally runs `ci-actions-verify verify` if the consumer has a DEPS.lock

Inputs:
- `scan-paths`: glob patterns to scan (default: `**/*.yml`)
- `lockfile`: path to DEPS.lock (default: `DEPS.lock`, skips verify if not found)
- `fail-on-warning`: whether warnings (dynamic refs, etc.) should fail the job (default: `false`)

### 8c. Scaffold Command (`ci-actions-verify init`)

Onboarding tool for new projects:

```
ci-actions-verify init [--dir .]
```

1. Scans all workflow and action YAML files in the directory
2. Extracts all `uses:` refs
3. Generates a `DEPS.lock` with placeholder hashes (ready for `ci-actions-verify lock`)
4. Generates a starter `SECURITY_CONTROLS.md` documenting the project's current state
5. Generates a starter `security-controls.json`
6. Prints a report of what it found: how many refs, how many pinned vs unpinned, recommended next steps

### 8d. Reusable Workflow

Callable workflow at `.github/workflows/verify.yml`:

```yaml
# In a consumer's workflow:
jobs:
  supply-chain:
    uses: butterflyskies/ci-actions/.github/workflows/verify.yml@<sha>
    with:
      lockfile: DEPS.lock  # optional
```

Runs as a separate job in the consumer's CI. Most opinionated — runs the full scan + verify pipeline, with GitHub annotations on failures.

### Invariants (Consumer Artifacts)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 81 | Release binaries have SHA256 checksums published alongside | Consumers need to verify download integrity, same as we do for rustup | P2 | Integration (release workflow) |
| 82 | `verify-deps` action downloads binary with SHA256 verification | The action must not trust the network blindly | P2 | Integration |
| 83 | `init` generates valid DEPS.lock (parseable by `ci-actions-verify`) | Scaffolded files must be correct input for our own tools | P6 | Integration |
| 84 | `init` identifies all `uses:` refs in a sample project | Must not miss refs — that's the whole point | P1 | Integration (fixture project) |
| 85 | Reusable workflow emits annotations on consumer PR | The value prop is zero-config PR feedback | P5 | Integration (CI) |
| 86 | Release binaries are built with `cargo-auditable` | Embedded dependency info for SBOM-level auditing of the tool itself | P5 | Integration (release workflow) |
| 87 | Release binaries have `attest-build-provenance` attestations | Dogfooding our own attestation practices | P1, P5 | Integration (release workflow) |

## Phase 9: Final Lock (implementation PR)

- Add all new action SHAs (attest-build-provenance) to DEPS.lock
- Run `ci-actions-verify lock` (or fall back to `scripts/lock-deps.sh`)
- Verify with `ci-actions-verify verify`
- Keep shell scripts in `scripts/` as bootstrap/fallback

## Files to Create/Modify

| File | Action |
|------|--------|
| `Cargo.toml` | Create |
| `Cargo.lock` | Generated |
| `rust-toolchain.toml` | Create |
| `.gitignore` | Update (add `/target/`) |
| `src/verify_main.rs` | Create |
| `src/deps_lock.rs` | Create |
| `src/actions_yaml.rs` | Create |
| `src/git.rs` | Create |
| `src/lock.rs` | Create |
| `src/verify.rs` | Create |
| `src/scan.rs` | Create |
| `src/bootstrap_main.rs` | Create |
| `src/rustup.rs` | Create |
| `src/rustup_hashes.rs` | Create (generated by `rustup-pin` command) |
| `src/rustup_pin.rs` | Create |
| `.github/workflows/ci.yml` | Rewrite |
| `.github/dependabot.yml` | Create |
| `.github/CODEOWNERS` | Create |
| `docker-publish/action.yml` | Update (attestation) |
| `setup-rust/action.yml` | Rewrite (remove dtolnay, add verified bootstrap) |
| `DEPS.lock` | Update (remove dtolnay, add new deps) |
| `README.md` | Update |
| `SECURITY.md` | Update |
| `SUPPLY_CHAIN.md` | Create |
| `src/tuf.rs` | Create (TUF sign/verify stubs, gated on `tuf` feature) |
| `SECURITY_CONTROLS.md` | Create (human-facing: principles → controls → invariants → gaps) |
| `security-controls.json` | Create (machine-readable: same data, for compliance tooling) |
| `tests/fixtures/*.yml` | Create (YAML parser test fixtures) |
| `tests/fixtures/DEPS.lock.*` | Create (lockfile parser test fixtures) |

## Security Principles

Every feature and invariant traces back to one of these principles. These are the "whys" — the threats we defend against and the properties we guarantee.

| ID | Principle | Threat | SLSA / SSDF Reference |
|----|-----------|--------|----------------------|
| P1 | **Dependency immutability** | Tag rewrite, force-push, ref mutation — an upstream action silently changes what code a SHA resolves to | SLSA Build L2 (hermetic), SSDF PW.4.1 |
| P2 | **Download integrity** | MITM, CDN compromise, DNS hijack — a network attacker substitutes a malicious binary for a legitimate one | SLSA Source L2 (verified), SSDF PW.4.2 |
| P3 | **Input sanitization** | Template injection — a malicious PR title or input value escapes into shell execution via `${{ }}` interpolation | OWASP CI/CD-SEC-4, SSDF PW.5.1 |
| P4 | **Least privilege** | Token theft, lateral movement — a compromised step uses overly broad permissions to access secrets or push code | SLSA Build L3 (isolated), SSDF PO.5.1 |
| P5 | **Auditability** | Silent supply chain drift — dependencies change without reviewable evidence | SLSA Source L1 (retained), SSDF PS.3.1 |
| P6 | **Parser correctness** | Confused deputy — a crafted lockfile or YAML causes the verifier to accept invalid input or skip checks | CWE-20 (Improper Input Validation) |
| P7 | **Fail closed** | Silent pass-through — verification errors are swallowed, allowing a compromised dependency to reach production | SSDF PW.6.1 |

### Deliverable: `SECURITY_CONTROLS.md` (human-facing)

A document in the repo root, structured by principle, that explains:
- What we're defending against (the threat, in plain language)
- How we defend against it (the mechanism)
- What we test (invariant IDs, linked to test functions)
- What we can't yet defend against (honest gaps)
- Framework references (SLSA, SSDF, OWASP CI/CD) for compliance reporting

### Deliverable: `security-controls.json` (machine-readable)

A JSON file at the repo root for automated compliance tooling:
```json
{
  "schema_version": "1.0.0",
  "project": "butterflyskies/ci-actions",
  "principles": [
    {
      "id": "P1",
      "name": "Dependency immutability",
      "threat": "Tag rewrite, force-push, ref mutation",
      "references": ["SLSA Build L2", "SSDF PW.4.1"],
      "controls": [
        {
          "id": "C1",
          "description": "All action refs pinned to 40-char commit SHAs",
          "invariants": ["I5", "I15", "I16", "I17", "I44", "I69"],
          "verification": "ci-actions-verify scan"
        }
      ]
    }
  ],
  "invariants": [
    {
      "id": "I1",
      "description": "Valid dep lines parse into (action, commit_sha, tree_hash) triples",
      "principle": "P6",
      "test_function": "tests::deps_lock::test_valid_line_parsing",
      "test_type": "unit"
    }
  ]
}
```

This enables: automated compliance dashboards, PR checks that link test failures to the principle they violate, and audit trail for security reviews.

## Invariants & Test Plan

Every invariant is listed with the principle it defends, the reason it exists, and how it's tested.

### DEPS.lock Parser (`src/deps_lock.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 1 | Valid dep lines parse into `(action, commit_sha, tree_hash)` triples | The lockfile is the source of truth for dependency identity; if parsing is wrong, verification is meaningless | P1, P6 | Unit |
| 2 | Comment lines (starting with `#`) are preserved verbatim on round-trip | Comments provide human context (section headers like `# --- setup-rust ---`); losing them degrades auditability of diffs | P5 | Unit |
| 3 | Blank lines are preserved on round-trip | Formatting changes create noise in diffs, hiding real dependency changes from reviewers | P5 | Unit |
| 4 | Section comments survive parse → serialize | Same as #2 — reviewers rely on section structure to navigate the lockfile | P5 | Unit |
| 5 | Lines not matching strict regex are rejected with line number | A malformed lockfile could cause the verifier to skip entries silently; strict parsing ensures every line is either a valid dep, a comment, or an error | P6, P7 | Unit |
| 6 | Uppercase hex in SHAs is rejected | Git SHAs are lowercase by convention; accepting mixed case could allow two entries for the "same" SHA to diverge | P6 | Unit |
| 7 | Trailing whitespace handled consistently | Inconsistent whitespace handling could cause a line to fail regex but contain a valid-looking dep that gets silently skipped | P6, P7 | Unit |
| 8 | `TREE_HASH_PLACEHOLDER` is parsed as valid | New deps added before running `lock` have placeholders; the parser must accept them so `lock` can populate them (but `verify` must warn) | P5 | Unit |
| 9 | Empty file parses to empty dep list | Edge case correctness — an empty lockfile is not an error condition, but it means nothing is verified | P6 | Unit |
| 10 | File with only comments parses to empty dep list | Same as #9 — all-comments is valid but should not cause a crash or false positive | P6 | Unit |
| 11 | Round-trip produces byte-identical output | If the serializer changes bytes, `git diff` shows phantom changes, obscuring real edits from reviewers | P5 | Unit |
| 12 | Action names with `/`, `-`, `_` parse correctly | Real action names like `docker/build-push-action` contain these characters; the regex must accept them | P6 | Unit |

### Actions YAML Parser (`src/actions_yaml.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 13 | Extracts `uses:` from composite action format | Composite actions (`runs.steps[].uses`) are our primary output; missing them means unverified dependencies | P1 | Unit |
| 14 | Extracts `uses:` from workflow format | Workflow files (`jobs.<name>.steps[].uses`) also contain action refs that need verification | P1 | Unit |
| 15 | SHA-pinned refs identified as pinned | Correct classification is the basis for all subsequent checks; a false negative means an unpinned ref slips through | P1 | Unit |
| 16 | Tag refs identified as unpinned | Tags are mutable — `@v2` can be moved to point at arbitrary code; this is the core attack vector | P1 | Unit |
| 17 | Branch refs identified as unpinned | Branches are even more mutable than tags; `@main` changes with every push | P1 | Unit |
| 18 | Dynamic `${{ }}` refs emit warning, not error | Dynamic refs can't be statically verified, but they're legitimate in templates/examples; blocking on them would be a false positive | P6 | Unit |
| 19 | Inline comments stripped from ref | YAML allows `action@sha # v2.0`; if the comment leaks into the ref, SHA validation breaks | P6 | Unit |
| 20 | `run:` steps silently skipped | `run:` steps don't reference actions; flagging them would be noise | P6 | Unit |
| 21 | Local workflow refs (`./.github/...`) identified as local | Local refs are first-party code, not third-party dependencies; checking them against DEPS.lock is wrong | P6 | Unit |
| 22 | Docker container refs (`docker://`) handled | Docker refs are a different dependency type; they need different verification (image signing, not tree hashes) | P6 | Unit |
| 23 | Malformed YAML produces clear error, not panic | A crafted YAML file must not crash the verifier — that would be a denial of verification | P6, P7 | Unit |
| 24 | No `uses:` refs returns empty list | Files with only `run:` steps are valid; they just don't have action dependencies | P6 | Unit |

### Git Operations (`src/git.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 25 | Known-good SHA returns correct tree hash | This is the core verification operation — if it returns wrong hashes, the entire security model is broken | P1 | Integration |
| 26 | Nonexistent SHA returns error | A deleted or nonexistent commit must not silently pass; it could mean the upstream repo was force-pushed | P1, P7 | Integration |
| 27 | Nonexistent repo returns error | A typo'd or deleted repo must be caught, not silently skipped | P7 | Integration |
| 28 | Temp directories cleaned up | Leaked temp dirs with cloned repo content are a minor info disclosure risk and a resource leak | Defense in depth | Integration |
| 29 | Same repo reuses clone dir | Performance invariant — fetching the same repo twice wastes time and network; the optimization must work correctly | Correctness | Unit |

### Lock Command (`src/lock.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 30 | Populates placeholder entries | The lock command's primary job; if it doesn't replace placeholders, new deps are unverified | P1 | Integration |
| 31 | Preserves existing hashes or re-confirms them | Either behavior is acceptable, but the command must not silently corrupt known-good hashes | P1, P5 | Integration |
| 32 | Preserves comments and formatting | Same as parser round-trip (#11) — diff noise hides real changes | P5 | Integration |
| 33 | Progress on stderr, not stdout | stdout may be piped or captured; mixing status with data breaks composability | Correctness | Integration |
| 34 | Exits 0 on success | Standard UNIX convention; CI gates on exit code | P7 | Integration |
| 35 | Exits non-zero on fetch failure | A partial lock (some deps fetched, some failed) must not silently succeed — that leaves gaps | P7 | Integration |

### Verify Command (`src/verify.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 36 | Passes when all hashes match | The happy path must work — a correct lockfile should not produce false positives | Correctness | Integration |
| 37 | Fails when any hash mismatches | This is the primary security gate — a mismatch means the upstream content changed, which is the attack we're detecting | P1, P7 | Integration |
| 38 | Emits `::error::` format for mismatches | GitHub Actions surfaces these as inline annotations on the PR; without them, failures are buried in logs | P5 | Integration |
| 39 | Warns on placeholders | Placeholders mean "not yet verified" — they're not failures, but reviewers must be alerted | P5 | Integration |
| 40 | Reports checked/failed counts | Auditors and reviewers need to confirm that all deps were actually checked, not silently skipped | P5, P7 | Integration |
| 41 | Fails on fetch errors | If we can't reach a repo, we can't verify it — this must block, not pass | P7 | Integration |

### Scan Command (`src/scan.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 42 | Finds refs in `*/action.yml` | Composite actions are the primary deliverable; their deps must be scanned | P1 | Integration |
| 43 | Finds refs in `.github/workflows/*.yml` | Workflow deps are equally important; the original shell lint only checked action.yml — this was a gap | P1 | Integration |
| 44 | Errors on unpinned refs | Unpinned refs (tags, branches) are the core vulnerability; this is the enforcement point | P1 | Integration |
| 45 | Errors on refs missing from DEPS.lock | A SHA-pinned ref without a lockfile entry has no tree hash to verify — it's unaudited | P1, P5 | Integration |
| 46 | Passes when everything is correct | False positives erode trust in the tool; the happy path must be clean | Correctness | Integration |
| 47 | Warns on dynamic refs | Can't be verified statically, but shouldn't block — they may be intentional in templates | P6 | Integration |
| 48 | Skips local workflow refs | Local refs are first-party; flagging them as "not in DEPS.lock" would be a false positive | P6 | Integration |
| 49 | Skips Docker container refs | Docker refs need image-level verification (cosign), not git tree hashes | P6 | Integration |
| 50 | Annotations include file path and line | Without location info, developers can't find and fix the issue | P5 | Integration |
| 51 | Correct exit codes | CI gates on exit code; wrong exit code = silent pass-through or false block | P7 | Integration |
| 52 | Scans nested directories | Example workflows in `examples/` contain `@main` refs that should be warned about | P1 | Integration |

### Rustup Bootstrap (`src/rustup.rs`, `src/rustup_hashes.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 53 | Hash lookup returns correct hash per target | If the wrong hash is returned, verification passes for a tampered binary or fails for a legitimate one | P2 | Unit |
| 54 | Unknown target returns clear error | Running on an unsupported platform must fail explicitly, not download an unverified binary | P2, P7 | Unit |
| 55 | SHA256 passes for matching file | The happy path — a legitimate download must not be rejected | Correctness | Unit |
| 56 | SHA256 fails for non-matching file | The security gate — a tampered binary must be caught before execution | P2, P7 | Unit |
| 57 | Download URL constructed correctly | A wrong URL could fetch a different binary entirely; the URL construction is security-relevant | P2 | Unit |
| 58 | All hardcoded hashes are exactly 64 hex chars | A truncated or malformed hash would weaken or break verification | P2, P6 | Unit |
| 59 | Rustup version is valid semver | Ensures we're requesting a real, known release — not a path traversal or injection | P2, P6 | Unit |

### CLI Integration (`verify_main.rs`, `bootstrap_main.rs`)

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 60 | `lock` exits 0 with valid lockfile | CI integration — the tool must compose correctly in workflows | Correctness | Integration |
| 61 | `verify` exits 0 with valid lockfile | Same as above | Correctness | Integration |
| 62 | `scan` exits 0 with valid repo | Same as above | Correctness | Integration |
| 63 | No subcommand prints help | Usability — user runs the tool wrong, gets guidance not a crash | Correctness | Integration |
| 64 | Bootstrap constructs correct rustup args | Wrong args = wrong toolchain installed = undefined build behavior | Correctness | Unit |
| 65 | `--help` works on all subcommands | Usability baseline | Correctness | Integration |

### Cross-cutting / End-to-end

| # | Invariant | Why | Principle | Test |
|---|-----------|-----|-----------|------|
| 66 | Scan + verify passes on this repo | Dogfooding — if our own tool can't verify our own repo, something is wrong | All | Integration (CI) |
| 67 | Shell scripts and Rust CLI produce identical results | The Rust CLI must be a faithful replacement, not a divergent reimplementation | Correctness | Integration (CI) |
| 68 | No `${{ }}` in `run:` blocks of our action.yml files | Template injection defense applied to ourselves | P3 | Integration (CI) |
| 69 | Every `uses:` in our files is SHA-pinned | Dependency immutability applied to ourselves | P1 | Integration (CI) |
| 70 | Every SHA-pinned ref has a DEPS.lock entry | Auditability applied to ourselves | P1, P5 | Integration (CI) |

### Test Infrastructure

- **Fixture files**: `tests/fixtures/` with sample YAML files covering all parser edge cases (valid workflows, composite actions, unpinned refs, dynamic refs, malformed YAML, Docker refs, local refs)
- **Fixture DEPS.lock files**: Valid, malformed, placeholder, mismatched
- **Network tests**: Gated behind `#[ignore]` so they don't break in sandboxed environments. CI runs them with `cargo nextest run --run-ignored all`.
- **`assert_cmd` + `predicates`**: For CLI integration tests (exit codes, stdout/stderr content)
- **Test naming convention**: `test_{module}_{invariant_number}_{short_description}` (e.g. `test_deps_lock_05_rejects_malformed_line`) — enables tracing from test failure back to invariant back to principle

## Verification (end-to-end)

1. `cargo fmt --check && cargo clippy -- -D warnings` pass
2. `cargo build --release` produces both `ci-actions-verify` and `ci-actions-bootstrap` binaries
3. `cargo nextest run` — all unit and integration tests pass (network tests may be `#[ignore]`'d locally)
4. `ci-actions-verify lock` populates DEPS.lock correctly (compare with shell script output)
5. `ci-actions-verify verify` passes with populated DEPS.lock
6. `ci-actions-verify scan` finds all `uses:` refs, flags missing/unpinned
7. `ci-actions-verify scan` on example files correctly warns about `@main` refs
8. Shell scripts produce identical results to Rust CLI (CI diff check)
9. Push to PR, CI workflow passes
