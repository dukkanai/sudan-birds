# Architecture and error boundaries

## Boundaries

Flutter calls Supabase with the current user session. PostgreSQL RLS, constraints and explicit column grants decide access. Profiles and contact information are separate. An authenticated viewer may reveal contact details only if the owner consented and block checks pass. Report details never become public.

Listings model both requests and offers. An offer requires a numeric price, currency and unit. Requests may use an optional budget. Currency is part of any price comparison. Educational information and consultations share one chronological feed. No payment or social-engagement tables are part of this version.

Cloudflare R2 is private object storage. A server may issue short-lived, object-specific upload permissions after verifying session, ownership and quota. A completed upload is not automatically publishable. The trusted verifier must decode bytes, reject malformed images and excessive dimensions, remove metadata, and write a verified canonical object. The foundation must remain fail-closed where that pipeline is not yet implemented.

## The requested try/catch envelope

Try/catch wraps meaningful asynchronous and external boundaries: application startup, repository requests, parsing, form actions and server handlers. Typed failures propagate to an accessible error state with retry when safe. Unexpected errors must not be silently converted into successful operations or empty results.

Flutter error hooks catch framework and asynchronous failures as a final safety net. These are not substitutes for local error handling. A class declaration cannot be wrapped in a Dart try statement; its fallible operations are wrapped instead. Pure getters and invariant-preserving constructors need validation rather than redundant empty catches.

Error reporting must use a fixed event identifier and safe category. Do not log exception strings, request bodies, URLs containing tokens, sessions, user contacts or secrets. Add a production observability provider only after its data-sharing and privacy settings are approved.

## Environment separation

The staged R2 bucket is private and empty. No production bucket or Supabase production project is configured in this code. Staging and production must have separate projects, sessions, secrets, storage and build identifiers. Public source code contains only example configuration.

## Deferred gates

See `verification.md` for executed checks and `release-runbook.md` for blocked deployment gates. Do not infer that a class, endpoint or screen is operational merely because it compiles.
