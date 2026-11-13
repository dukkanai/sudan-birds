// These primitives are inert until a reviewed broker/outbox calls them. Never
// attach upstream errors, response bodies, tokens or credentials to this error.
export type AppleErrorCode =
  | "apple_input_invalid"
  | "apple_binding_invalid"
  | "apple_token_invalid"
  | "apple_response_invalid"
  | "apple_redirect_rejected"
  | "apple_request_rejected"
  | "apple_configuration_required"
  | "apple_rate_limited"
  | "apple_unavailable"
  | "apple_transport_failed"
  | "apple_timeout"
  | "apple_crypto_failed";

export class AppleError extends Error {
  constructor(readonly code: AppleErrorCode, readonly outcomeUnknown = false) {
    super(code);
    this.name = "AppleError";
  }
}

export function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function boundedText(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max &&
    /^[\x21-\x7e]+$/.test(value);
}
