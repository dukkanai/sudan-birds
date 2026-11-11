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
# Reviewed Auth transport, R2 lifetime/canonical deadline, bounded streams,
# media/codec/trial graph, fixture/driver and dependency resolution. These pins
# admit the current harness; they never relabel historical measurements.
# Refuse to run after source drift; review correspondence before updating pins.
if ! sha256sum --check --status <<'PINS'
843bb541a46b9827915a8584e67888b73e1e2ab28c2d27246a6f8f7214752ba3  supabase/functions/_shared/r2.ts
9d13e1270e5c5ccf426eac2d60a76d7403fce56513d740160bd8be59fa9a3b61  supabase/functions/_shared/presign.ts
cbc217cde13ae0dbb345c25ba293ec4c25e8ea997334d501303ad1f5c4229419  supabase/functions/_shared/image_stream.ts
2d0fcf4de9cda2e63eda394aae18e8d5acd37a9b6249c4f6cda72532c1425171  supabase/functions/_shared/stream_cleanup.ts
71a07623170872d815c347d19f8a0dfe12fec7dff22ebe82508395310ca79242  supabase/functions/_shared/diagnostics.ts
05aa0a48a28fcecf7fd930465ee36a231d1826fc48bf542b5a88c66c7e757911  supabase/functions/_shared/auth.ts
2ebe32a7e4e6dc6bd45735af7d6e0e6c653278980e607056ca08a2955ddbebe5  supabase/functions/_shared/backend_fetch.ts
3cb3314183986f65e9892b7a46eab8414222a5ad2c0e56c4c8b668db0f909f39  supabase/functions/_shared/http.ts
660ca9f3088d371e0474c227a50235fab9621626278c743c43155be2f3372a98  supabase/functions/_shared/media_service.ts
9f901fd45685d0f0fb8ec5c3c6e1ee9bbbf77202d4a50f769da24e26fbe99a2c  supabase/functions/_shared/media_trial.ts
949968cb02c2d544c0e58cff6b5d366cade1424536fe69bdee88166acf44f155  supabase/functions/_shared/codec_capacity.ts
ab419165810611f0f4af87e21a1a5a1781675232b99dd92ddb05ad2d56cd7ee6  supabase/functions/_shared/images.ts
64d8091e5e142b119a9f6bc6b1def276675a755a9d5f28968e3a78c158265898  supabase/functions/_shared/bounded_jpeg_encoder.ts
6d489b33c6db0818fdf5c004dc7f5d8341e73c9ea1ecf03c8fb7e37c1fe3f55c  supabase/functions/_shared/upload_input.ts
f2c1422d5318b67242408688fd8b055c1758f3389960561105b214d3866cee79  supabase/functions/media/handler.ts
3e304154903bd9097aceae3e637d2c874102f815aeff560563af267c87507eb7  supabase/functions/codec-diagnostic/fixture.ts
18779b40d0ac92e9cf47e9d53bc7bd28ff1abf03a81fb23f1f8d7846bb8484e8  supabase/functions/deno.json
a8027750a8273c9d7a8e11a2566ec1b65102023f325be2238190c7edfe246490  supabase/functions/package.json
3c980053a79328461b27e2152932fe289bb6f53da59270ec9b6fbe5aaba05170  supabase/functions/package-lock.json
89029cb284a630644f958fcfba161de0f71cbd3d3d975dc76687ac2e40dac76b  scripts/media_sdk_fixture.ts
8d4931574b1eebfb82ad0bfbca62459ff01f6cb33578bc04f3b58a8a61613e71  scripts/media_sdk_resource.ts
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
