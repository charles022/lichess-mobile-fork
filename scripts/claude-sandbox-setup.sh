#!/usr/bin/env bash
# Setup for ephemeral development sandboxes (e.g. Claude Code web sessions).
#
# Fresh sandbox containers have no Flutter SDK, and their egress proxy blocks the
# GitHub-release download that the `sqlite3` Dart package's build hook performs on the
# first `flutter test` (the tests' in-memory database needs libsqlite3). This script:
#
#   1. installs the Flutter version pinned in pubspec.yaml (if `flutter` is not on PATH)
#   2. appends a LOCAL-ONLY override to pubspec.yaml making the sqlite3 build hook link
#      the system libsqlite3 instead of downloading a prebuilt one
#   3. runs `flutter pub get` and `dart run build_runner build`
#
# IMPORTANT: step 2 modifies pubspec.yaml in the working tree. NEVER commit that change —
# it is only correct inside the sandbox. Exclude pubspec.yaml when staging, or run
# `git checkout -- pubspec.yaml` before committing.

set -euo pipefail
cd "$(dirname "$0")/.."

FLUTTER_VERSION=$(sed -n 's/^  flutter: \([0-9.]*\)$/\1/p' pubspec.yaml)
SDK_DIR=/opt/flutter-sdk

if ! command -v flutter > /dev/null; then
  if [ ! -x "$SDK_DIR/flutter/bin/flutter" ]; then
    echo "Installing Flutter $FLUTTER_VERSION to $SDK_DIR ..."
    mkdir -p "$SDK_DIR"
    curl -sSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      | tar xJ -C "$SDK_DIR"
  fi
  export PATH="$SDK_DIR/flutter/bin:$PATH"
  git config --global --add safe.directory "$SDK_DIR/flutter" || true
fi
flutter --version | head -1

if ! grep -q 'user_defines:' pubspec.yaml; then
  echo "Applying LOCAL-ONLY sqlite3 system-library override to pubspec.yaml (do not commit)"
  cat >> pubspec.yaml << 'EOF'

# LOCAL DEV ONLY (do not commit): use system sqlite3 because the sandbox proxy
# blocks the github release download of the prebuilt binary.
hooks:
  user_defines:
    sqlite3:
      source: system
EOF
fi

flutter pub get
dart run build_runner build --delete-conflicting-outputs

echo
echo "Sandbox setup done. Remember:"
echo "  - add $SDK_DIR/flutter/bin to PATH in new shells if needed"
echo "  - pubspec.yaml now has a local-only change; never commit it"
