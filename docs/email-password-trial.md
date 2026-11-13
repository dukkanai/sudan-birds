# iPhone TestFlight email/password trial

The current staging build uses existing Supabase email/password accounts. It does
not create accounts, configure providers or include a password in source/build
configuration. Google and Apple controls are unavailable; OAuth implementation is
retained for later and is disabled by default in the application repository.

The Arabic account screen opens an accessible, scrollable login form. The password
field is obscured, suggestions/personalized keyboard learning are disabled, and its
controller is cleared before the request. Only sanitized session credentials are
persisted in the existing OS-backed secure storage; the password is not persisted.

Each password attempt uses an isolated Auth client. Recent generation checks and
serialized secure persistence/main-session installation prevent canceled, timed-out
or superseded requests from installing a late session. Cancellation and signout
preserve the existing durable restore fence. Uncertain cleanup remains visible and
retryable, rather than being reported as confirmed server revocation.

Local tests use synthetic credentials and mocked HTTP only. They do not establish
that a real account can sign in on the hosted project or that TestFlight upload,
installation, or on-device secure storage has passed on this revision. Those must
be verified separately before claiming a working delivered trial.

No Android APK work is part of this trial change. The unfinished Apple grant
integration was retained separately for later work, not included or deployed here.
