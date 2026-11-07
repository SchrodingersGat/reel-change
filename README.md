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
- **Camera or Zebra scanner:** scan with the device camera, or with the built-in scanner on a Zebra device (see [Zebra scanners](#zebra-scanners)).
- **Hands-free operation:** optionally return to step 1 automatically after a transfer, and keep the screen on during a reel swap.
- **Self-signed servers:** trust a server's self-signed certificate after checking its fingerprint. If the certificate ever changes, the app asks again.
- **Activity log:** view, filter and copy a log of the current session for troubleshooting. It is cleared when the app closes and never contains passwords or session details.

## Requirements

- An Android device with a camera, or a Zebra Android device with DataWedge, for scanning barcodes (barcodes can also be typed in by hand)
- Access to an InvenTree server, with an account that can view parts and stock and transfer stock items

## Zebra scanners

On Zebra Android devices the built-in scanner can be used instead of the camera:

1. Open **Settings** (gear icon) and choose **Zebra scanner (DataWedge)** under **Scanner**.
2. The app creates a DataWedge profile called **Reel Change** for itself, which sends scans to the app. If the profile is later changed or removed, it is set up again when the app starts, or with **SET UP DATAWEDGE PROFILE** in Settings.
3. Press the scanner trigger to scan the empty reel (step 1) or verify the replacement reel (step 2). The **SCAN** buttons also work, and wait for the trigger.

Scans are only accepted while the app is open and set to use the Zebra scanner. A scan only looks up the barcode; nothing is transferred until the user confirms step 3.

## Building from source

The app is built with Flutter, using [fvm](https://fvm.app) to pin the version:

```sh
fvm flutter pub get
fvm flutter run
```

To try the Zebra scanner option on a device or emulator without a Zebra scanner, set the scanner to DataWedge in Settings and send a scan with adb:

```sh
adb shell am broadcast -a org.inventree.reel_change.SCAN --es com.symbol.datawedge.data_string "INV-SI330"
```

## Credits

Parts of the sign-in code are adapted from the official InvenTree app. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
