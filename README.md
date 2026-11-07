<p align="center">
  <img src="assets/images/logo.png" alt="Reel Change app icon" width="128">
</p>

# Reel Change

Reel Change is an Android companion app for [InvenTree](https://inventree.org). It makes sure the right reel goes onto an SMT machine: the operator confirms the exact manufacturer part number (MPN) before a reel is loaded, and the stock transfer is recorded in InvenTree as part of the same step.

## Loading a reel

A reel change is a guided three-step workflow:

1. **Scan part:** scan the empty reel coming off the machine and confirm its MPN.
2. **Select reel:** choose a replacement reel from the source location. Reels with an exact MPN match are listed first, then approved alternates. The chosen reel must be confirmed by scanning its label, and loading an alternate needs an extra confirmation.
3. **Load:** check the quantity (the full reel by default, adjustable if needed) and transfer the reel into the machine location.

Progress is shown at the bottom of the screen, and **RESET** is always available to start over.

Parts or reels with missing or incorrect data in InvenTree are flagged clearly, so they can be fixed rather than loaded by mistake.

## Features

- **InvenTree sign-in:** log in with an existing InvenTree account, including two-factor authentication. The app signs back in automatically on launch, and the password is never stored on the device.
- **Permission check:** at login the app confirms the user has the InvenTree roles needed for reel changes, and lists any that are missing.
- **Location settings:** choose the source and machine stock locations. They are checked against the server each time the app starts.
- **Hands-free operation:** optionally return to step 1 automatically after a transfer, and keep the screen on during a reel swap.
- **Self-signed servers:** trust a server's self-signed certificate after checking its fingerprint. If the certificate ever changes, the app asks again.
- **Activity log:** view, filter and copy a log of the current session for troubleshooting. It is cleared when the app closes and never contains passwords or session details.

## Requirements

- An Android device with a camera for scanning barcodes (barcodes can also be typed in by hand)
- Access to an InvenTree server, with an account that can view parts and stock and transfer stock items

## Building from source

The app is built with Flutter, using [fvm](https://fvm.app) to pin the version:

```sh
fvm flutter pub get
fvm flutter run
```

## Credits

Parts of the sign-in code are adapted from the official InvenTree app. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
