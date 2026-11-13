#!/usr/bin/env bash
# Explicit local-only run; installs nothing, starts no listener or service.
set -euo pipefail
if [ "$#" -ne 2 ] || [ "$1" != '--run-local' ]; then
  echo 'Usage: DENO_BIN=/absolute/deno DENO_DIR=/absolute/cache bash scripts/media_bundle_resource.sh --run-local sequential|sequential-paced|burst|boundaries' >&2
  exit 2
fi
case "$2" in sequential|sequential-paced|burst|boundaries) ;; *) exit 2 ;; esac
case "${DENO_BIN:-}" in /*) ;; *) echo 'DENO_BIN must be an absolute pinned Deno 2.5.6 binary' >&2; exit 2 ;; esac
case "${DENO_DIR:-}" in /*) ;; *) echo 'DENO_DIR must be an absolute prepared cache directory' >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."
# Only SDK metadata names, in an otherwise empty environment. No host secrets.
SDK_ENV='SMITHY_NEW_RETRIES_2026,AWS_LAMBDA_NODEJS_NO_GLOBAL_AWSLAMBDA,AWS_LAMBDA_BENCHMARK_MODE,AWS_NEW_RETRIES_2026,AWS_SDK_JS_NODE_VERSION_SUPPORT_WARNING_DISABLED,AWS_PROFILE,AWS_SHARED_CREDENTIALS_FILE,HOME,USERPROFILE,HOMEPATH,HOMEDRIVE,AWS_CONFIG_FILE,AWS_LAMBDA_FUNCTION_NAME,_X_AMZN_TRACE_ID,AWS_LAMBDA_MAX_CONCURRENCY'
exec env -i PATH=/usr/bin:/bin DENO_DIR="$DENO_DIR" \
  timeout --signal=TERM --kill-after=5s 120 "$DENO_BIN" run \
  --cached-only --no-remote --no-lock --no-prompt --node-modules-dir=manual \
  --deny-net --deny-read --deny-write --deny-run --deny-sys --deny-ffi \
  --allow-env="$SDK_ENV" --config supabase/functions/deno.json \
  scripts/media_bundle_resource.ts "$@"
