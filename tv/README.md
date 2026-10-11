# TapTether Smart TV Targets

The Flutter mobile app can build an experimental Android TV APK, but its UI is not yet tailored for D-pad navigation or the Play Store TV requirements.

LG webOS and Samsung Tizen require **separate vendor SDK targets**. A normal Flutter iOS/Android build cannot produce installable webOS `.ipk` or Tizen `.tpk` packages automatically. Hardware/firmware support varies. The provided LG/Samsung build scripts intentionally fail with clear instructions rather than produce fake deliverables.

**Planned approach:** Support LG/Samsung remote control from the mobile app through local TV network APIs *without installing an app on the TV* first. Investigate installable TV Flutter targets only if they add meaningful functionality. TV operating systems limit background control and input injection.
