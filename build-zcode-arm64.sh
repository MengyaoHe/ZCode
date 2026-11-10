#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != aarch64 ]]; then
  echo 'This build requires Linux ARM64.' >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_archive="$script_dir/ZCode-official-source.tar.gz"
printf '%s  %s\n' '257dbfe9062ac8b28a99c7c7c5850b080220dfc77d574706bb10d472ae99be36' "$source_archive" | sha256sum -c -

build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT
tar -xzf "$source_archive" -C "$build_dir" --strip-components=1
cd "$build_dir"

# Keep the package store and caches in the writable build environment.
export npm_config_store_dir="$build_dir/.build-cache/pnpm-store"
export XDG_CACHE_HOME="$build_dir/.build-cache/xdg"
export XDG_DATA_HOME="$build_dir/.build-cache/data"
mkdir -p "$npm_config_store_dir" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

cat mise.toml
node --version
pnpm --version

# This verified source snapshot vendors the CLI. Bootstrap still tries to
# initialize it as a submodule, which requires metadata absent from archives.
test -f apps/zcode-cli/package.json
test -f apps/zcode-cli/packages/cli/package.json
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
const path = "scripts/bootstrap.mjs";
const source = readFileSync(path, "utf8");
const submodule = 'runGit(["submodule", "update", "--init", "--recursive", "apps/zcode-cli"]);';
if (source.split(submodule).length !== 2) {
  throw new Error("Unexpected bootstrap script: review the submodule initialization.");
}
writeFileSync(path, source.replace(submodule, '// CLI sources are included in this archive.'));
JS

if pnpm bootstrap; then
  :
else
  bootstrap_status=$?
  patch_file="$build_dir/patches/@ai-sdk__anthropic@3.0.81.patch"
  sdk_dir="$build_dir/node_modules/@ai-sdk/anthropic"
  if [[ -f "$patch_file" && -f "$sdk_dir/package.json" ]]; then
    echo '[diagnostic] Installed Anthropic SDK version:'
    node -p "require('./node_modules/@ai-sdk/anthropic/package.json').version" || true
    echo '[diagnostic] Forward patch check:'
    (cd "$sdk_dir" && git apply --check "$patch_file") || true
    echo '[diagnostic] Reverse patch check:'
    (cd "$sdk_dir" && git apply --reverse --check "$patch_file") || true
  fi
  exit "$bootstrap_status"
fi
# This deliverable targets Web. Omit the standalone TUI asset collector.
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
const path = "scripts/build-zcode.mjs";
const source = readFileSync(path, "utf8");
const stage = "  await stageTuiRuntime(packageRoot);";
if (source.split(stage).length !== 2) throw new Error("Unexpected TUI staging call");
writeFileSync(path, source.replace(stage, "  // Standalone TUI omitted for Web deployment."));
JS
pnpm build:zcode --base-url https://downloads.example.com/zcode/

version=$(node -p "require('./dist/zcode/latest.json').version")
archive="dist/zcode/releases/$version/zcode-$version.tar.gz"
mkdir runtime-check
tar -xzf "$archive" -C runtime-check
node runtime-check/zcode/bin/zcode.mjs --web --help

cp -- "$archive" "$script_dir/zcode-linux-arm64.tar.gz"
cd "$script_dir"
sha256sum zcode-linux-arm64.tar.gz > zcode-linux-arm64.tar.gz.sha256
