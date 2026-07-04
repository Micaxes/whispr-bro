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
# Output: Vendor/llama.xcframework (+ Vendor/llama.xcframework.sha256).
# Requires: full Xcode, cmake (brew install cmake), libtool.

set -euo pipefail

LLAMA_TAG="b9862"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DEPLOY_TARGET="14.0"

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode required" >&2; exit 1; }

# Persistent work dir so re-runs are incremental (clone + configure are cached).
WORK="$ROOT/.build-llama"
SRC="$WORK/llama.cpp"
STAMP="$WORK/.tag"
mkdir -p "$WORK"

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
else
  echo "== reusing clone at $SRC (tag $LLAMA_TAG)"
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

echo "done: $VENDOR/llama.xcframework (llama.cpp $LLAMA_TAG)"
