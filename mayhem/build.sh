#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the KAT probe
# and the project's own (clean, non-sanitized) test binaries used by mayhem/test.sh.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent). Two toolchains are
# installed: the pinned nightly ($RUST_CHANNEL, for -Zsanitizer=address on the fuzz
# targets) and `stable` (for the project's own test suite + the KAT probe — an
# unrelated dev-dependency break on a bleeding-edge nightly must not sink the oracle).
# Always use an explicit `+toolchain` — never bare `cargo` — so a future upstream
# rust-toolchain.toml can never silently hijack these invocations.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

RUST_CHANNEL="${RUST_CHANNEL:-nightly-2025-06-01}"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids
# ASan backtraces. The rlenv PATCH tier prepends `-C debuginfo=2`; we don't fight it.
# Debug-info contract (SPEC §6.2 item 10): DWARF <= 3 on the fuzz binaries, threaded via RUSTFLAGS.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3}"
# Sanitizer contract: $SANITIZER_FLAGS comes from the base ENV (clang syntax); rustc takes
# -Zsanitizer instead, so map non-empty -> ASan and an EXPLICIT empty -> no sanitizer.
SANITIZER_FLAGS="${SANITIZER_FLAGS=-fsanitize=address}"
RUST_SANITIZER=""
[ -n "$SANITIZER_FLAGS" ] && RUST_SANITIZER="-Zsanitizer=address"
# The libFuzzer C++ runtime inside libfuzzer-sys is compiled by the cc crate with clang
# (DWARF-5 default) — pin it to DWARF-3 too.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers"

# DWARF<4 first-CU anchor: rustc's prebuilt ASan runtime ships DWARF-5 and would land at
# .debug_info offset 0. Link a clang -gdwarf-3 anchor object FIRST (PREPENDED — must be the
# first linker argument for its CU to land at offset 0) via a -Clinker cc-wrapper so the
# first CU is DWARF-3.
ANCHOR_DIR=/tmp/mayhem-dwarf3
mkdir -p "$ANCHOR_DIR"
echo 'int __mayhem_dwarf3_anchor;' > "$ANCHOR_DIR/anchor.c"
clang -c -gdwarf-3 -O0 -o "$ANCHOR_DIR/anchor.o" "$ANCHOR_DIR/anchor.c"
printf '#!/usr/bin/env bash\nexec cc %s "$@"\n' "$ANCHOR_DIR/anchor.o" > "$ANCHOR_DIR/cc-wrap.sh"
chmod +x "$ANCHOR_DIR/cc-wrap.sh"
FUZZ_RUSTFLAGS="$FUZZ_RUSTFLAGS -Clinker=$ANCHOR_DIR/cc-wrap.sh"

# Additive cargo-fuzz crate (NOT upstream's own fuzz/, which is a member of the ROOT
# workspace and would force a root-level Cargo.lock outside mayhem/ — see
# mayhem/fuzz/Cargo.toml). Its fuzz_targets/*.rs are byte-for-byte copies of upstream's.
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo +$RUST_CHANNEL fuzz build (ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo "+$RUST_CHANNEL" fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  # FUZZ_DIR has its own empty [workspace] table, so it is its OWN workspace root and
  # cargo puts binaries under ITS OWN target dir (not the outer project's).
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# === KAT probe (mayhem/kat) — a small, dynamically linked binary that mayhem/test.sh
# invokes directly and asserts exact stdout against. Built with `stable`, no sanitizer:
# it is the ORACLE, not a fuzz target, and must stay a normal (non-neutered-by-default)
# build so the sabotage-shim proof is meaningful.
echo "=== building KAT probe (mayhem/kat) ==="
cargo +stable build --manifest-path mayhem/kat/Cargo.toml --release
KAT_BIN="$SRC/mayhem/kat/target/release/apollo-rs-kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe binary not found at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/apollo-rs-kat
# Regression guard: the KAT probe must stay dynamically linked (Rust binaries are by
# default) so the sabotage shim can actually intercept it.
file /mayhem/apollo-rs-kat | grep -q 'dynamically linked' \
  || { echo "ERROR: KAT probe is not dynamically linked — sabotage detection would be blind to it" >&2; exit 1; }
echo "built /mayhem/apollo-rs-kat"

# Build the project's TEST suite too — with the project's NORMAL flags (a clean,
# non-sanitized build), on `stable` (see toolchain note above), so mayhem/test.sh only
# RUNS it (no compile at test time). Upstream CI runs `cargo test --all-features` from
# the workspace root.
echo "=== building the upstream test suite (cargo +stable test --no-run) ==="
cargo +stable test --workspace --all-features --no-run

echo "build.sh complete"
