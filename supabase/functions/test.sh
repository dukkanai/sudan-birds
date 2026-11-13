#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# Only SDK runtime/config metadata. No credential values, file reads, network,
# or sys access are permitted; presigning uses fixed synthetic credentials.
export HOME="${HOME:-/tmp/sudan-birds-test-home}"
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=default
SDK_ENV='SMITHY_NEW_RETRIES_2026,AWS_LAMBDA_NODEJS_NO_GLOBAL_AWSLAMBDA,AWS_LAMBDA_BENCHMARK_MODE,AWS_NEW_RETRIES_2026,AWS_SDK_JS_NODE_VERSION_SUPPORT_WARNING_DISABLED,AWS_PROFILE,AWS_SHARED_CREDENTIALS_FILE,HOME,USERPROFILE,HOMEPATH,HOMEDRIVE,AWS_CONFIG_FILE,AWS_LAMBDA_FUNCTION_NAME,_X_AMZN_TRACE_ID,AWS_LAMBDA_MAX_CONCURRENCY'
exec "${DENO_BIN:-deno}" test --allow-env="$SDK_ENV" --node-modules-dir=manual .
