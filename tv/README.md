# TapTether Smart TV Targets

## iPhone-to-LG remote (0.8.1)

The current TapTether iPhone app supports direct SSAP LAN pairing and remote
control of compatible LG webOS TVs. No installation on the TV is required.
The native mobile implementation is in `app/lib/lg_webos_client.dart` and
`app/lib/lg_webos_screen.dart`. The optional companion below is unrelated to
that TV remote functionality.

## LG webOS companion prototype

An installable webOS web application source project now lives in tv/lg-webos. It has a local interactive UI that responds to LG remote navigation. It makes no internet connection.

With the current LG webOS CLI installed (ares-package), build via:

    ./bin/2c-tt-lg-tv.sh

Output appears in dist/lg-webos. Enable Developer Mode on your LG TV, configure the TV in the LG CLI, and install using ares-install with your configured device and the generated .ipk.

This is a companion proof of concept, **not** a system-wide keyboard/mouse agent or a functioning phone-to-TV remote. Ordinary webOS TV apps are sandboxed. A future iPhone LG TV remote should use LG's local-network pairing API where supported by the TV model and firmware.

## Android TV

Experimental Android TV APK support exists, but the Flutter screen is designed for phones rather than TV remote/D-pad focus.

## Samsung Tizen

No working Tizen agent/app is shipped yet. Vendor SDK and separate app implementation are required.

Scripts should never claim to produce usable LG/Samsung binaries if the vendor tooling is missing.
