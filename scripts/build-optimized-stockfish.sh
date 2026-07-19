#!/usr/bin/env bash
# Build a host-optimized Stockfish binary for the external engine provider.

set -euo pipefail

TAG="${STOCKFISH_TAG:-sf_18}"
ARCH="${STOCKFISH_ARCH:-native}"
OUTPUT="${STOCKFISH_OUTPUT:-}"
REPO="${STOCKFISH_REPO:-https://github.com/official-stockfish/Stockfish.git}"

usage() {
  cat <<'EOF'
Usage: build-optimized-stockfish.sh [options]

Options:
  --tag TAG       Stockfish git tag (default: sf_18).
  --arch ARCH     Stockfish build architecture (default: native).
  --output PATH   Installed binary path. Defaults to
                  /usr/local/bin/stockfish-VERSION-ARCH.
  -h, --help      Show this help.

Environment variables: STOCKFISH_TAG, STOCKFISH_ARCH, STOCKFISH_OUTPUT,
STOCKFISH_REPO.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

for command in git make nproc sha256sum strip; do
  if ! command -v "$command" > /dev/null; then
    err "required command not found: $command"
    exit 1
  fi
done
if ! command -v curl > /dev/null && ! command -v wget > /dev/null; then
  err "curl or wget is required to download the NNUE networks"
  exit 1
fi

BUILD_DIR=$(mktemp -d)
trap 'find "$BUILD_DIR" -depth -delete 2>/dev/null || true' EXIT

prepare_fedora_cxx() {
  local root="$BUILD_DIR/toolchain"
  local package rpm_file target version lib_dir system_lib_dir file tool path runtime

  for command in dnf rpm rpm2cpio cpio gcc; do
    if ! command -v "$command" > /dev/null; then
      err "g++ is missing. Install a C++ compiler and rerun this script."
      return 1
    fi
  done

  log "Preparing a temporary Fedora C++ toolchain"
  mkdir -p "$root/rpms" "$root/root"
  dnf download --destdir "$root/rpms" \
    "gcc-c++-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' gcc)" \
    "libstdc++-devel-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' libstdc++)"

  for rpm_file in "$root"/rpms/*.rpm; do
    (cd "$root/root" && rpm2cpio "$rpm_file" | cpio -idm --quiet)
  done

  CXX="$root/root/usr/bin/g++"
  target=$("$CXX" -dumpmachine)
  version=$("$CXX" -dumpversion)
  lib_dir="$root/root/usr/lib/gcc/$target/$version"
  system_lib_dir=$(dirname "$(gcc -print-libgcc-file-name)")

  ln -s "$(gcc -print-file-name=include)" "$lib_dir/include"
  for file in "$system_lib_dir"/*; do
    if [ ! -e "$lib_dir/${file##*/}" ] && [ ! -L "$lib_dir/${file##*/}" ]; then
      ln -s "$file" "$lib_dir/${file##*/}"
    fi
  done

  for tool in liblto_plugin.so lto-wrapper lto1; do
    path=$(gcc -print-prog-name="$tool")
    if [ "$path" != "$tool" ] && [ ! -e "$root/root/usr/libexec/gcc/$target/$version/$tool" ]; then
      ln -s "$path" "$root/root/usr/libexec/gcc/$target/$version/$tool"
    fi
  done

  runtime=$(rpm -ql libstdc++ | awk '/\/libstdc\+\+\.so\.6$/ {print; exit}')
  ln -sf "$runtime" "$lib_dir/libstdc++.so"
}

if command -v g++ > /dev/null; then
  CXX=$(command -v g++)
else
  prepare_fedora_cxx
fi

log "Checking out Stockfish $TAG"
git clone --depth 1 --branch "$TAG" "$REPO" "$BUILD_DIR/source"

if [ "$ARCH" = native ]; then
  ARCH=$("$BUILD_DIR/source/scripts/get_native_properties.sh" | cut -d ' ' -f 1)
fi
if [ -z "$OUTPUT" ]; then
  OUTPUT="/usr/local/bin/stockfish-${TAG#sf_}-${ARCH#x86-64-}"
fi

log "Building Stockfish $TAG for $ARCH with profile-guided optimization"
make -C "$BUILD_DIR/source/src" -j "$(nproc)" profile-build \
  ARCH="$ARCH" COMP=gcc COMPCXX="$CXX"
strip "$BUILD_DIR/source/src/stockfish"

if [ ! -d "$(dirname "$OUTPUT")" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    install -d "$(dirname "$OUTPUT")"
  else
    sudo install -d "$(dirname "$OUTPUT")"
  fi
fi

log "Installing $OUTPUT"
if [ -w "$(dirname "$OUTPUT")" ]; then
  install -m 0755 "$BUILD_DIR/source/src/stockfish" "$OUTPUT"
else
  sudo install -o root -g root -m 0755 "$BUILD_DIR/source/src/stockfish" "$OUTPUT"
fi

if ! printf 'uci\nisready\neval\nquit\n' | "$OUTPUT" 2>&1 |
    grep "NNUE evaluation using" > /dev/null; then
  err "the installed binary failed its NNUE verification"
  exit 1
fi

log "Build complete"
echo "  Binary: $OUTPUT"
echo "  Target: $ARCH"
echo "  SHA-256: $(sha256sum "$OUTPUT" | awk '{print $1}')"
