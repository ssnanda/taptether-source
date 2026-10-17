# Ubuntu screen indicator disappears during Live

On GNOME, the orange pill near the Wi-Fi indicator signals an active
ScreenCast/PipeWire screen-sharing session. It is normal for the indicator
to disappear **after an idle Snapshot session**: the helper pauses capture
after 35 seconds without requests for privacy. For Live, successful
authenticated frames should keep the session active.

## Diagnosed implementation issue and repair

The original `respond()` path ran
`GLib.idle_add(pipeline.set_state, Gst.State.PLAYING)` for every live frame.
`set_state` returns a `Gst.StateChangeReturn` enum, which is truthy on
success/async transitions. GLib therefore repeatedly rescheduled the
callback, potentially starving GLib's event loop and causing screencast
failure. The replacement `resume_pipeline_once()` always returns **False**,
ensuring it executes once per request, not indefinitely. The screen helper
now also emits non-sensitive, actionable portal and pipeline errors to
systemd user journal / its tray diagnostic log. No screenshots are logged.

This repair is **Ubuntu agent-only** and keeps the IPA, APK, other agents,
macOS Input Core/Screen Core, pairing keys, and MJPEG unchanged.

### What to verify on a physical GNOME Ubuntu desktop

1. From the Ubuntu tray choose **Settings → Screen Helper → Restart**.
2. On the iPhone choose **Live**, approve the GNOME ScreenCast prompt, and
   verify the indicator stays active while frames update.
3. Try **Snapshot**; the indicator may disappear after 35 seconds of
   inactivity (expected), then return on next scheduled or manual request.
4. If Live still stops, use **Settings → Screen Helper → Diagnostics** and
   send the error text, or run:
   `~/.local/bin/taptetherctl screen-status`
   This includes the latest user-service journal messages and, if present,
   the tray-launched `~/.cache/taptether/screen-helper.log`.

The regression tests protect against direct GStreamer state callbacks in
`GLib.idle_add`. Actual Ubuntu screen permission, PipeWire frame output,
and iPhone live touch behavior require physical testing.
