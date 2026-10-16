/// Planned shared visual-control modes for v0.7.
/// The corresponding OS capture and authenticated streaming transports
/// will be enabled only when implemented and granted screen permissions.
enum VisualMode { trackpad, snapshot, live }

extension VisualModeLabel on VisualMode {
  String get label => switch (this) {
    VisualMode.trackpad => 'Trackpad',
    VisualMode.snapshot => 'Snapshot',
    VisualMode.live => 'Live',
  };
}

class VisualModePolicy {
  const VisualModePolicy._();

  static const snapshotInterval = Duration(seconds: 15);

  static String normalize(String? value) =>
      const {'trackpad', 'snapshot', 'live'}.contains(value)
          ? value! : 'trackpad';
}
