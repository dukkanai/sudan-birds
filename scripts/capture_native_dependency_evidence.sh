#!/usr/bin/env bash
# Called only after the existing native build succeeds. No builds or uploads here.
set -euo pipefail
umask 077
platform="${1:?android or ios required}"
case "$platform" in android|ios) ;; *) echo 'Unsupported native evidence platform.' >&2; exit 1 ;; esac
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RUNNER_TEMP:?CI temporary directory required}"
output="$RUNNER_TEMP/native-evidence-$platform"
test ! -e "$output" && test ! -L "$output"
raw="$(mktemp -d "$RUNNER_TEMP/native-capture-$platform.XXXXXX")"
trap 'rm -rf "$raw"' EXIT
capture() {
  local name="$1"
  shift
  # Do not print raw failure logs: tools can include private paths or credentials.
  if ! "$@" > "$raw/$name" 2>&1; then
    echo 'Native evidence command failed. Raw output suppressed; artifact upload blocked.' >&2
    exit 1
  fi
}
cd "$repo/app"
capture flutter.json flutter --version --machine
if [ "$platform" = android ]; then
  : "${GRADLE_USER_HOME:?Reuse the build job Gradle home}"
  cmp android/ci/flutter-plugin-repositories.init.gradle \
    "$GRADLE_USER_HOME/init.d/flutter-plugin-repositories.init.gradle"
  cd android
  # --offline reuses what the successful build resolved; no second online graph.
  capture gradle.txt ./gradlew --offline --no-daemon --console=plain --version
  capture android-debugRuntimeClasspath.txt ./gradlew --offline --no-daemon --console=plain \
    :app:dependencies --configuration debugRuntimeClasspath
  capture android-tink-insight.txt ./gradlew --offline --no-daemon --console=plain \
    :app:dependencyInsight --configuration debugRuntimeClasspath --dependency com.google.crypto.tink:tink-android
else
  capture xcode.txt xcodebuild -version
  capture cocoapods.txt pod --version
fi
cd "$repo"
python3 scripts/native_dependency_evidence.py stage --platform "$platform" \
  --repo "$repo" --raw "$raw" --output "$output"
