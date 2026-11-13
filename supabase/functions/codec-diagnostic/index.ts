import { createCodecDiagnostic } from "./handler.ts";
// Deployment operator MUST replace with one fixed UTC deadline <=20minutes away.
// An invalid/expired literal is intentionally fail-closed in the committed source.
Deno.serve(createCodecDiagnostic("EXPIRED_UNTIL_EXPLICIT_STAGING_TEST", undefined));
