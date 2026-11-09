#!/usr/bin/env bash
# Explicit local-only run; installs nothing, starts no listener or service.
set -euo pipefail
if [ "$#" -ne 2 ] || [ "$1" != '--run-local' ]; then
  echo 'Usage: DENO_BIN=/absolute/deno DENO_DIR=/absolute/cache bash scripts/media_sdk_resource.sh --run-local sequential|sequential-paced|burst|boundaries|counterfactual-no-destroy' >&2
  exit 2
fi
case "$2" in sequential|sequential-paced|burst|boundaries|counterfactual-no-destroy) ;; *) exit 2 ;; esac
case "${DENO_BIN:-}" in /*) ;; *) echo 'DENO_BIN must be an absolute pinned Deno 2.5.6 binary' >&2; exit 2 ;; esac
case "${DENO_DIR:-}" in /*) ;; *) echo 'DENO_DIR must be an absolute prepared cache directory' >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."
# Only SDK metadata names, in an otherwise empty environment. No host secrets.
# Reviewed R2 lifetime/canonical deadline, bounded streams, timed trial gate,
# and dependency resolution. This supplements, never relabels, old measurements.
# Refuse to run after source drift; review correspondence before updating pins.
if ! sha256sum --check --status <<'PINS'
3d5d123807e591ac2d0c87cfb0614221a0bcfb267333e1b4cd285608bf04b0ec  supabase/functions/_shared/r2.ts
9d13e1270e5c5ccf426eac2d60a76d7403fce56513d740160bd8be59fa9a3b61  supabase/functions/_shared/presign.ts
15da1ef31bbd24a6f2fd3ab2aa725609a2c8f2803ed2e264e50fd277589aebcf  supabase/functions/_shared/image_stream.ts
e6993502583a43b07e98912a6bb15c13a2b76db547b5aaf5aa2102560de292e8  supabase/functions/package-lock.json
f2c1422d5318b67242408688fd8b055c1758f3389960561105b214d3866cee79  supabase/functions/media/handler.ts
9f901fd45685d0f0fb8ec5c3c6e1ee9bbbf77202d4a50f769da24e26fbe99a2c  supabase/functions/_shared/media_trial.ts
PINS
then
  echo 'Reviewed SDK source/dependency pin changed; stop and review adapter correspondence.' >&2
  exit 2
fi
SDK_ENV='SMITHY_NEW_RETRIES_2026,AWS_LAMBDA_NODEJS_NO_GLOBAL_AWSLAMBDA,AWS_LAMBDA_BENCHMARK_MODE,AWS_NEW_RETRIES_2026,AWS_SDK_JS_NODE_VERSION_SUPPORT_WARNING_DISABLED,AWS_PROFILE,AWS_SHARED_CREDENTIALS_FILE,HOME,USERPROFILE,HOMEPATH,HOMEDRIVE,AWS_CONFIG_FILE,AWS_LAMBDA_FUNCTION_NAME,_X_AMZN_TRACE_ID,AWS_LAMBDA_MAX_CONCURRENCY'
exec env -i PATH=/usr/bin:/bin DENO_DIR="$DENO_DIR" HOME=/nonexistent-sudan-sdk-home \
  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=default \
  timeout --signal=TERM --kill-after=5s 120 "$DENO_BIN" run \
  --cached-only --no-remote --no-lock --no-prompt --node-modules-dir=manual \
  --deny-net --deny-read --deny-write --deny-run --deny-sys --deny-ffi \
  --allow-env="$SDK_ENV" --config supabase/functions/deno.json \
  scripts/media_sdk_resource.ts "$@"
