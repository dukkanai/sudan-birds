# Mobile session, interruption and release checks

This is implementation evidence, not release approval or proof of physical-device security.

## Credentials and restore permission

- `flutter_secure_storage` is pinned to 11.2.0. Both Supabase session persistence and PKCE adapters are supplied explicitly. There is no plaintext credential fallback or legacy-session migration; the app has no released sessions to migrate.
- Android uses the plugin's Keystore defaults in an app/project-scoped namespace, with automatic reset and algorithm migration disabled. iOS uses first-unlock, this-device-only Keychain accessibility, synchronization off, and only the app's own Keychain access group. These options do not protect an unlocked, compromised or rooted device, nor establish that every native dependency has been audited.
- A separate native **nonsecret** restore permission contains only an allow/block value scoped by public project host. Android synchronously commits it in private, backup-excluded preferences. iOS writes an atomic file in Application Support, excludes its directory/file from backup, synchronizes the file and checks readback. No session, token, verifier, account identity or draft image is written there.
- Startup checks this permission before any secret read or SDK restoration. Missing/malformed permission blocks restoration, including after reinstall where Keychain data may survive. A blocked startup removes only the two app-owned secure keys; unavailable storage fails closed into local preview.
- Logout first quarantines the in-memory identity, then persists the block permission **before** SDK logout and secret deletion. If deletion fails after that, a new process still cannot restore the old session. If the block permission itself cannot be saved, no SDK/network/deletion effects are attempted and no durable logout is claimed. The previous permission may still exist on disk: the user must retry cleanup when storage works. No software can promise a persisted logout when every durable write fails.
- Native operations are bounded to five seconds, but a timeout does not cancel native work or free the serialization queue. The aggregate SDK initialization has no non-canceling outer timeout that could create an orphan client after fallback.

## OAuth lifecycle and network interruption

- Only the existing staging callback contract is accepted. No hosted allowlist, provider credential, production domain association or store identity is configured by this patch.
- Supabase's automatic URI consumer is disabled. The app owns callbacks and creates an isolated GoTrue client for each browser flow. Verifier reads/writes/removes are bound to that flow generation. A previous HTTP exchange cannot delete a newer verifier or install its response into the main SDK client.
- A current result is saved securely before main-client installation. Installation and logout share a serialized lifecycle gate. Logout invalidates the flow before awaiting that gate; a new login is rejected during pending installation/logout. The repository continues to hide quarantined SDK identities.
- Duplicate callbacks do not repeat an exchange. Browser launch failure, cancellation/error callback and a 20-second exchange timeout clear the current flow and display a safe retry message. Late HTTP completion remains isolated and generation-fenced. A cold-start callback has no live flow ownership and requires a fresh login, even if a verifier survived process death.
- Interrupted Android image selection is discarded and the user is asked to select again. Recovery starts after the first application frame is scheduled, does not infer an account/listing, and does not reset a route the user has already opened. No draft image is persisted by the Dart recovery policy. Native picker/cache behavior still needs device testing.

## Evidence and remaining gates

Synthetic Flutter tests exercise failed secure reads/writes/removes, marker failure/restart, no fallback, real SDK delayed PKCE HTTP responses, duplicate/cold callbacks, launch denial, timeout, logout during persistence/installation, replacement login and disposal. Tests use fabricated identities and mocked transport, not real provider/device credentials. Widget tests cover Arabic large-text/layout semantics and delayed picker recovery; they do not prove VoiceOver/TalkBack operation.

Still required on the final exact commit/artifact:

1. All required CI checks, including native Kotlin/Swift compilation and unsigned Android/iOS builds. The local Linux environment has no Android SDK or Xcode. Passing Dart tests does not compile the new native fence channel.
2. Physical iOS/Android Keychain/Keystore availability, first unlock/relock, write/remove failures, process termination, restart, reinstall, OS backup/restore and Android device transfer. Verify power-loss behavior of the native fence and that secrets and restore permissions do not transfer. Confirm no unintended Keychain access group entitlement.
3. Real staging Google/Apple sign-in, cancellation, duplicate/cold/warm deep links, weak network, expired/revoked tokens and account switching through the actual hosted API. Synthetic SDK traces are not provider, redirect-ownership or cryptographic proof.
4. Real VoiceOver/TalkBack focus order, labels, dynamic type, screen zoom, orientation, keyboard and image-picker interruption tests on supported devices.
5. Final name/branding and store IDs, non-template icons/splash, signing, privacy/store declarations, authenticated account-deletion review and signed internal distribution. Flutter template app/launch artwork has not been replaced or approved as final branding.
6. Native/transitive dependency security and license review for the resolved lockfile and signed artifacts. Pinning and verifying the main archive checksum does not constitute a full dependency vulnerability audit, native supply-chain review or reproducible signed build.
