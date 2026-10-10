#!/usr/bin/env bash
# build-llama-xcframework.sh — build llama.cpp as a self-contained
# macos-arm64 llama.xcframework with Metal (embedded shaders), pinned + hashed.
#
# Only the macOS/arm64 slice is built (the upstream build-xcframework.sh builds
# all four Apple platforms). We compile static libs, merge them, then wrap in a
# dynamic framework with -force_load so the ggml backend-registration
# constructors (Metal/CPU/BLAS) survive — the same trick upstream uses. Metal
# shaders are embedded (GGML_METAL_EMBED_LIBRARY), so no runtime .metallib.
#
# Local patches: every scripts/patches/llama.cpp/*.patch is applied, in name
# order, on top of the pristine pinned tag. See the "patches" block below for
# how a cached .build-llama is kept honest about which set it carries.
#
# Output: Vendor/llama.xcframework (+ Vendor/llama.xcframework.sha256).
# Requires: full Xcode, cmake (brew install cmake), libtool.
#
#   --check   build nothing: exit 0 if Vendor/llama.xcframework was built from
#             this checkout's tag + patches, 1 if not (make-app.sh asks first).

set -euo pipefail

LLAMA_TAG="b9862"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEPLOY_TARGET="14.0"

# The patch set this checkout wants. PATCH_ID is the tag plus a hash of the exact
# bytes of that set. It goes two places: on the cached clone, to know what its
# tree was last brought to (below), and into the finished framework's Info.plist,
# so anything that bundles the framework can tell whether it was built from THIS
# set. Vendor/llama.xcframework is gitignored: a merge changes the patches and
# leaves an old framework behind, silently carrying the bug the patch fixed.
PATCH_DIR="$ROOT/scripts/patches/llama.cpp"
PATCHES=()
for p in "$PATCH_DIR"/*.patch; do
  if [[ -f "$p" ]]; then PATCHES+=("$p"); fi
done
if [[ ${#PATCHES[@]} -gt 0 ]]; then
  PATCH_ID="$LLAMA_TAG $(cat "${PATCHES[@]}" | shasum -a 256 | cut -d' ' -f1)"
else
  PATCH_ID="$LLAMA_TAG none"
fi
PATCH_KEY="WhisprBroPatchID"
FW_PLIST="$VENDOR/llama.xcframework/macos-arm64/llama.framework/Resources/Info.plist"

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "$FW_PLIST" ]] || { echo "missing $VENDOR/llama.xcframework -- run scripts/build-llama-xcframework.sh" >&2; exit 1; }
  HAVE="$(/usr/libexec/PlistBuddy -c "Print :$PATCH_KEY" "$FW_PLIST" 2>/dev/null || true)"
  if [[ "$HAVE" != "$PATCH_ID" ]]; then
    if [[ -n "$HAVE" ]]; then HAVE="${HAVE:0:22}..."; else HAVE="(none: built before patches were recorded)"; fi
    echo "Vendor/llama.xcframework was not built from this checkout's llama.cpp patches:" >&2
    echo "  framework: $HAVE" >&2
    echo "  checkout:  ${PATCH_ID:0:22}..." >&2
    echo "run scripts/build-llama-xcframework.sh (incremental: only the patched files rebuild)" >&2
    exit 1
  fi
  echo "llama.cpp $LLAMA_TAG + ${#PATCHES[@]} local patch(es): framework matches scripts/patches/llama.cpp"
  exit 0
fi
[[ $# -eq 0 ]] || { echo "usage: $0 [--check]" >&2; exit 2; }

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode required" >&2; exit 1; }

# Persistent work dir so re-runs are incremental (clone + configure are cached).
WORK="$ROOT/.build-llama"
SRC="$WORK/llama.cpp"
STAMP="$WORK/.tag"
PATCH_STAMP="$WORK/.patches"
mkdir -p "$WORK"
# $SRC sits inside this checkout. If its .git were ever unusable, git would walk
# up and `reset --hard` / `clean` the OUTER repo -- so it may not.
export GIT_CEILING_DIRECTORIES="$WORK"

# Wipe the cache if the pinned tag changed, so a bump never reuses stale source
# or a stale cmake configure.
if [[ -f "$STAMP" && "$(cat "$STAMP")" != "$LLAMA_TAG" ]]; then
  echo "== tag changed ($(cat "$STAMP") -> $LLAMA_TAG); clearing $WORK"
  rm -rf "$WORK"
  mkdir -p "$WORK"
fi

if [[ ! -d "$SRC/.git" ]]; then
  echo "== cloning llama.cpp @ $LLAMA_TAG"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$SRC"
  echo "$LLAMA_TAG" > "$STAMP"
  # Pristine, whatever the stamp of the clone it replaces says.
  rm -f "$PATCH_STAMP"
else
  echo "== reusing clone at $SRC (tag $LLAMA_TAG)"
fi

# --- patches ----------------------------------------------------------------
# PATCH_STAMP records PATCH_ID, the tag plus a hash of the exact bytes of the
# patch set, that the tree in $SRC was last brought to. Fresh clone, a cache from
# before a patch existed, an edited patch, a run killed half way: none of them
# match, so the tree is reset to the pristine tag and the WHOLE set is applied
# again. The result is always "tag + exactly these patches" -- never unpatched,
# never stacked. A matching stamp is a no-op: the files keep their mtimes and
# cmake rebuilds nothing. (A patch that stops applying -- upstream fixed it, or
# the tag moved under it -- fails loudly here; drop or port it.)
#
# A stamp says where the tree was taken, not that it is still there: a clone
# redone by hand, `git checkout -- .`. So a matching stamp is believed only if
# every patch still reverse-applies, i.e. is really in the tree. (Patches that
# edit each other's lines would fail that and be re-applied on every run: slower,
# never wrong.)
patches_in_tree() {
  local p
  for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
    git -C "$SRC" apply --reverse --check "$p" >/dev/null 2>&1 || return 1
  done
}

if [[ "$(cat "$PATCH_STAMP" 2>/dev/null || true)" == "$PATCH_ID" ]] && patches_in_tree; then
  echo "== llama.cpp patches already applied (${#PATCHES[@]})"
else
  git -C "$SRC" rev-parse -q --verify "refs/tags/$LLAMA_TAG^{commit}" >/dev/null \
    || { echo "cached clone at $SRC is not $LLAMA_TAG -- delete $WORK and re-run" >&2; exit 1; }
  echo "== resetting llama.cpp to $LLAMA_TAG, applying ${#PATCHES[@]} patch(es)"
  rm -f "$PATCH_STAMP"
  git -C "$SRC" reset -q --hard "refs/tags/$LLAMA_TAG"
  git -C "$SRC" clean -qfd
  # ${PATCHES[@]+...} guards empty-array expansion under `set -u` on bash 3.2.
  for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
    echo "   $(basename "$p")"
    git -C "$SRC" apply "$p"
  done
  echo "$PATCH_ID" > "$PATCH_STAMP"
fi

if [[ ! -f "$WORK/build/CMakeCache.txt" ]]; then
  echo "== configuring (static, Metal embedded, arm64)"
  GEN=(); command -v ninja >/dev/null && GEN=(-G Ninja)
  # ${GEN[@]+...} guards empty-array expansion under `set -u` on bash 3.2 (macOS).
  cmake -S "$SRC" -B "$WORK/build" ${GEN[@]+"${GEN[@]}"} \
    -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=ON \
  -DGGML_OPENMP=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_CURL=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET"
else
  echo "== reusing cmake configure ($WORK/build)"
fi

echo "== building (llama lib + its ggml/Metal deps only; skips the app/ target)"
cmake --build "$WORK/build" --config Release -j"$(sysctl -n hw.ncpu)" \
  --target llama ggml ggml-base ggml-cpu ggml-metal ggml-blas

echo "== merging static libraries"
# bash 3.2 (macOS) has no mapfile; collect with a read loop.
LIBS=()
while IFS= read -r lib; do LIBS+=("$lib"); done < <(find "$WORK/build" -name '*.a' | sort -u)
[[ ${#LIBS[@]} -gt 0 ]] || { echo "no static libs produced" >&2; exit 1; }
printf '  %s\n' "${LIBS[@]}"
COMBINED="$WORK/libllama_combined.a"
rm -f "$COMBINED"
libtool -static -o "$COMBINED" "${LIBS[@]}" 2>/dev/null

echo "== wrapping in a dynamic framework (force_load keeps ggml backends)"
FW="$WORK/framework/llama.framework"
rm -rf "$FW"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Modules" "$FW/Versions/A/Resources"
# Copy ONLY the C headers the macOS build needs. Other backend headers
# (openvino/sycl/cann/cpp…) are C++-only (include <cstring>/<memory>) and would
# break the Swift/C module build with '"This header is for C++ only"'.
cp "$SRC/include/llama.h" "$FW/Versions/A/Headers/"
for h in ggml.h ggml-opt.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h; do
  cp "$SRC/ggml/include/$h" "$FW/Versions/A/Headers/"
done

clang++ -dynamiclib \
  -Wl,-force_load,"$COMBINED" \
  -framework Metal -framework MetalKit -framework Accelerate -framework Foundation \
  -mmacosx-version-min="$DEPLOY_TARGET" -arch arm64 \
  -install_name "@rpath/llama.framework/Versions/A/llama" \
  -o "$FW/Versions/A/llama"

cat > "$FW/Versions/A/Modules/module.modulemap" <<'EOF'
framework module llama {
    umbrella "Headers"
    link "c++"
    link framework "Metal"
    link framework "Accelerate"
    link framework "Foundation"
    export *
}
EOF

cat > "$FW/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.ggml.llama</string>
  <key>CFBundleName</key><string>llama</string>
  <key>CFBundleExecutable</key><string>llama</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>$LLAMA_TAG</string>
  <key>MinimumOSVersion</key><string>$DEPLOY_TARGET</string>
  <key>$PATCH_KEY</key><string>$PATCH_ID</string>
</dict></plist>
EOF

# Framework symlinks.
ln -sf A "$FW/Versions/Current"
ln -sf Versions/Current/llama "$FW/llama"
ln -sf Versions/Current/Headers "$FW/Headers"
ln -sf Versions/Current/Modules "$FW/Modules"
ln -sf Versions/Current/Resources "$FW/Resources"

echo "== creating xcframework"
rm -rf "$VENDOR/llama.xcframework"
mkdir -p "$VENDOR"
xcodebuild -create-xcframework -framework "$FW" -output "$VENDOR/llama.xcframework"

echo "== recording checksum"
(cd "$VENDOR" && zip -qry -X llama.xcframework.zip llama.xcframework \
  && shasum -a 256 llama.xcframework.zip | tee llama.xcframework.sha256 \
  && rm -f llama.xcframework.zip)

echo "done: $VENDOR/llama.xcframework (llama.cpp $LLAMA_TAG + ${#PATCHES[@]} local patch(es))"
