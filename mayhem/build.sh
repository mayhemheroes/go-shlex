#!/usr/bin/env bash
#
# go-shlex/mayhem/build.sh — build google/shlex's OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer_v2.
#
# OSS-Fuzz target (projects/go-shlex/build.sh):
#   compile_native_go_fuzzer_v2 github.com/google/shlex FuzzLexer FuzzLexer
# i.e. the NATIVE go-fuzz harness `func FuzzLexer(f *testing.F)` (mayhem/fuzz_test.go), built
# with go-118-fuzz-build, then linked with $LIB_FUZZING_ENGINE (harness: mayhem/fuzz_lexer_harness.go.src,
# copied to the repo root as fuzz_test.go at build time). The harness drives the shell-style
# lexer: NewLexer over arbitrary bytes, iterating .Next() until io.EOF. The fuzzed surface is the
# Tokenizer/Lexer scanStream() state machine (quoting / escaping / comment handling).
#
# We produce:
#   /mayhem/fuzz_lexer   — OSS-Fuzz target  (shlex.FuzzLexer, go-118-fuzz-build, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-118-fuzz-build builder); we link
# it against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like the OSS-Fuzz
# compile path's final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain is pinned under /opt/toolchains (SPEC §6.2 item 8); GOMODCACHE is set in the
# Dockerfile ENV and survives the PATCH re-run under a different $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

# The go-118-fuzz-build tool lives on PATH via /opt/toolchains/go-path/bin (set in the Dockerfile).
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# OSS-Fuzz copies fuzz_test.go into the repo root (package shlex); replicate that so
# go-118-fuzz-build sees FuzzLexer in the shlex package directory. We ship the harness in mayhem/
# as a NON-.go file (fuzz_lexer_harness.go.src) so the Go toolchain never tries to compile it as a
# stray `package shlex` _test.go inside the mayhem/ directory (which would break `go test ./...`).
cp "$SRC/mayhem/fuzz_lexer_harness.go.src" "$SRC/fuzz_test.go"

# go-118-fuzz-build rewrites source + needs the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: shlex.FuzzLexer via go-118-fuzz-build (func FuzzLexer(f *testing.F)) ────────
#     go-118-fuzz-build wants the package DIRECTORY; FuzzLexer lives in the repo-root pkg `shlex`.
echo "=== building fuzz_lexer (shlex.FuzzLexer, go-118-fuzz-build) ==="
go-118-fuzz-build -o "$SRC/mayhem-build/fuzz_lexer.a" -func FuzzLexer "$SRC"
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_lexer.a" -o /mayhem/fuzz_lexer
echo "built /mayhem/fuzz_lexer"

echo "build.sh complete:"
ls -la /mayhem/fuzz_lexer 2>&1 || true
