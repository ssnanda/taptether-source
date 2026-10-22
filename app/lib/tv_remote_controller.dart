/// Common local-only control contract for LG webOS and Samsung Smart TVs.
/// Unsupported information may return null or an empty app list.
abstract interface class TvRemoteController {
  bool get connected;
  bool get pointerIsRelative;
  Future<void> button(String name);
  Future<void> pointerMove(int dx, int dy);
  Future<void> pointerClick();
  Future<void> insertText(String text);
  Future<void> volumeUp();
  Future<void> volumeDown();
  Future<void> mute(bool muted);
  Future<void> channelUp();
  Future<void> channelDown();
  Future<List<({String id, String title})>> apps();
  Future<void> launchApp(String appId);
  Future<String?> foregroundApp();
  Future<String?> currentChannel();
  Future<int?> volumeLevel();
  Future<void> powerOff();
  Future<void> disconnect();
}
