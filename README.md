# SMT Reel Loader

Android companion app for InvenTree: verify exact MPNs when loading reels onto an SMT machine. See `plan.md` for the full work plan.

**Status:** login / auto-login, location settings, and the three-step reel-loading workflow:

1. **Scan part:** scan the empty reel and confirm the MPN against the SMT machine. Reels with no MPN link stop here with a data error.
2. **Select reel:** pick a reel from the source location (exact MPN matches first, then alternates, then reels needing a data fix). The reel must be verified by scanning its label. Alternates need an extra confirmation.
3. **Load:** review and adjust the quantity (default is the full reel), then transfer it into the machine location.

Progress is shown at the bottom of the screen, and RESET is always available.

## Setup

Flutter is pinned with [fvm](https://fvm.app) (`.fvmrc` → 3.41.6). Prefix all Flutter commands with `fvm`:

```sh
fvm flutter pub get
fvm flutter analyze
fvm flutter test
```

Code is formatted with `dart format`, and CI fails on unformatted code. Install the [pre-commit](https://pre-commit.com) hook once per clone, so formatting is applied on every commit:

```sh
pip install pre-commit   # if not already installed
pre-commit install
```

If the hook reformats files, the commit is stopped. Re-stage the changes and commit again.

## CI

GitHub Actions (`.github/workflows/`), triggered on push / PR to `master`:

- **CI** (`ci.yaml`): format check, `flutter analyze`, unit tests (excluding the `live` tag), coverage artifact
- **Android** (`android.yaml`): debug APK build, uploaded as an artifact

Both read the Flutter version from `.fvmrc`.

## Running against a local InvenTree server

On the Android emulator, forward the device's `localhost:8000` to the dev machine. The app then uses `http://localhost:8000` directly, which matches the server's `ALLOWED_HOSTS`:

```sh
adb reverse tcp:8000 tcp:8000
fvm flutter run
```

Live login tests (skipped unless configured; credentials come from the environment, never from files):

```sh
INVENTREE_TEST_SERVER=http://localhost:8000 \
INVENTREE_TEST_USERNAME=<user> INVENTREE_TEST_PASSWORD=<password> \
fvm flutter test test/live_server_test.dart
```

## Authentication

Session (cookie) authentication through InvenTree's allauth headless API, mirroring the official InvenTree app. Ported code is listed in `THIRD_PARTY_NOTICES.md`.

- `lib/auth/auth_service.dart`: launch-time session restore, login (+ TOTP MFA), logout, 401 → login
- `lib/auth/session_store.dart`: cookie jar bound to the server origin (ported verbatim)
- `lib/core/api_client.dart`: HTTP client (CSRF headers; credentials only sent to the configured server; TLS always validated; redirects never followed)
- `lib/core/credential_store.dart`: server address, username and session cookies kept in Android secure storage. The password is never stored, and app backup is disabled.
