#!/usr/bin/env bash
# What CI runs (AGENTS §Verification gate). Exit code is the verdict.
#   format lint (strict) -> architecture checks + their self-test -> build
#   (warnings are errors) -> no web framework linked -> tests (including the
#   package-level disconnect-restart drill) -> headless replay smoke.
# Xcode is selected with DEVELOPER_DIR (this Mac's xcode-select points at the
# Command Line Tools); CI sets it to the runner's pinned Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

step() { printf '\n==> %s\n' "$*"; }

step "toolchain"
xcodebuild -version
swift --version 2>&1 | head -1
sw_vers -productVersion

step "deployment target is not newer than this macOS (D-023)"
target="$(grep -Eo '\.macOS\("[0-9]+' Package.swift | grep -Eo '[0-9]+$')"
host="$(sw_vers -productVersion | cut -d. -f1)"
echo "deployment target macOS $target, host macOS $host"
if [ "$target" -gt "$host" ]; then
  echo "check: the deployment target (macOS $target) is newer than this runner (macOS $host)" >&2
  exit 1
fi

step "format (swift format lint --strict)"
swift format lint --strict --recursive Package.swift Sources Tests

step "architecture checks"
scripts/arch-check.sh
scripts/test-arch-check.sh

step "build (warnings are errors)"
swift build --build-tests -Xswiftc -warnings-as-errors

step "built products link no web framework"
scripts/arch-check.sh --binaries "$(swift build --show-bin-path)"

step "tests"
swift test --skip-build

if [ -x scripts/replay.sh ]; then
  step "headless replay smoke"
  scripts/replay.sh --smoke
fi

printf '\ncheck: all green\n'
