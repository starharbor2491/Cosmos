#!/bin/zsh
# Puts the CEF build Cosmos is built against in Vendor/CEF (git-ignored): downloads the minimal distribution from CEF's
# own build server, checks its SHA-1, unpacks it, and compiles CEF's C++ wrapper into Vendor/CEF/build/. Does nothing
# when that build is already there.
# Usage: scripts/fetch-cef.sh
cd "${0:A:h}/.." || exit 1
version='156.0.14+g4fa4ab5+chromium-156.0.8078.48'
# The stable API Cosmos is written against (Package.swift passes the same value): a newer CEF build that still supports
# it can be loaded without rebuilding Cosmos.
api=15600
# The oldest macOS Cosmos runs on (Package.swift's platform): the wrapper is built for it too.
macos=14.0
case $(uname -m) in
  arm64) platform=macosarm64; sha1=7359a9d293dd5c480bec3f18b762731b483b0e13 ;;
  *) platform=macosx64; sha1=bc46c83878741fa2b23486940dacebabb294bf39 ;;
esac
dest=Vendor/CEF

# The wrapper (libcef_dll, and the two Objective-C++ files that load the framework and the sandbox), with the flags
# CEF's own cmake files use on macOS, four files at a time. It is built again when any of the stamp changes.
build_wrapper() {
  local out=$dest/build stamp="$api macOS $macos with sandbox"
  [[ -f $out/libcef_dll_wrapper.a && -f $out/.api && $(<$out/.api) == $stamp ]] && return 0
  echo "[fetch-cef] compiling CEF's wrapper" >&2
  rm -rf "$out.tmp" && mkdir -p "$out.tmp" || return 1
  (cd "$dest" && { find libcef_dll -name '*.cc'; print -l libcef_dll/wrapper/cef_scoped_{library_loader,sandbox_context}_mac.mm } |
    xargs -P 4 -n 1 zsh -c 'f=$1; case $f in *.mm) l=objective-c++;; *) l=c++;; esac
      clang++ -c -x $l -mmacosx-version-min='$macos' -std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility=hidden \
        -fvisibility-inlines-hidden -O2 -DWRAPPING_CEF_SHARED -DCEF_API_VERSION='$api' -I. $f -o build.tmp/${f//\//_}.o 2>/dev/null || { echo "failed: $f" >&2; exit 255; }' _) || return 1
  ar rcs "$out.tmp/libcef_dll_wrapper.a" "$out.tmp"/*.o && rm -f "$out.tmp"/*.o && print $stamp > "$out.tmp/.api" &&
    rm -rf "$out" && mv "$out.tmp" "$out"
}

if [[ -f $dest/.cosmos-version && $(<$dest/.cosmos-version) == "$version $platform" ]]; then build_wrapper; exit $?; fi

name="cef_binary_${version}_${platform}_minimal"
url="https://cef-builds.spotifycdn.com/${name//+/%2B}.tar.bz2"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
echo "[fetch-cef] downloading $name (about 140 MB)" >&2
curl -fL --retry 3 -o "$work/cef.tar.bz2" "$url" || { echo "[fetch-cef] download failed" >&2; exit 1; }
got=$(shasum -a 1 "$work/cef.tar.bz2" | cut -d' ' -f1)
[[ $got == $sha1 ]] || { echo "[fetch-cef] SHA-1 is $got, expected $sha1" >&2; exit 1; }
tar -xjf "$work/cef.tar.bz2" -C "$work" || exit 1
rm -rf "$dest"
mkdir -p "${dest:h}"
mv "$work/$name" "$dest" || exit 1
print -r -- "$version $platform" > "$dest/.cosmos-version"
echo "[fetch-cef] CEF $version is in $dest" >&2
build_wrapper
