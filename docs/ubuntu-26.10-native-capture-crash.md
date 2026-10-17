# Ubuntu 26.10 crash: Screen Helper malloc failure

Observed during iPhone Live screen viewing:

- Ubuntu apport identifies `/usr/share/taptether/taptether_screen.py`.
- `ProblemType: Crash`; `AssertionMessage: malloc(): invalid size (unsorted)`.
- The GNOME orange screen-sharing indicator briefly appears then goes away.
- The iPhone may additionally show a `BAD_DECRYPT` error for
  `https://<local-address>:48321/api/live`. This may be a downstream
  stream/network failure or an independent TLS issue; it is not a GNOME
  screen-sharing permission message.

## Agent-only 0.7.8+71 repair

The previous helper used a native GStreamer RGB buffer mapped into Python,
interpreted a video stride, decoded the buffer with Pillow, resized and
JPEG-encoded on the GStreamer streaming thread. Native heap corruption in
this path is a strong candidate for the `malloc` assertion, though a
machine-specific crash trace is still required to prove its root cause.

The repair converts, bounds and JPEG-encodes within GStreamer:

- `videoconvert ! videoscale add-borders=true ! video/x-raw,width=1280,height=720,format=I420 ! jpegenc quality=65 ! appsink`.
- Python receives **JPEG bytes only**, using `Gst.Buffer.extract_dup`
  rather than mapping/unmapping raw memory or invoking Pillow.
- It checks frame bounds, JPEG start/end markers, expected encoded caps,
  and the required encoder/scaler plugins.
- Stream frames remain private and in memory; no cloud or frame logging.
- Existing portal consent flow, MJPEG transport and normal idle capture
  behavior remain unchanged.

This version is deliberately **Ubuntu-only**. It does not change the mobile
IPA/APK, Windows/macOS agents or macOS Input Core/Screen Core. The full
app version remains 0.7.7+70 while Ubuntu advances to 0.7.8+71.

## After installing from the Ubuntu tray

1. Ensure `taptetherctl check-update` reports Ubuntu 0.7.8+71.
2. Select **Settings → Screen Helper → Restart Screen Helper** in Ubuntu.
3. Open Live on iPhone and approve GNOME screen sharing as usual.
4. If a crash persists, obtain
   `~/.local/bin/taptetherctl screen-status` and
   `journalctl --user -u taptether-screen.service -n 50 --no-pager`.
   Do not send pairing keys or any screen contents.

The automated regression tests verify the encoded-frame callback and
release packaging. **Physical Ubuntu 26.10 verification remains necessary.**
