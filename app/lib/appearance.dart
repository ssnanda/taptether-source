import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// No account or cloud settings; presentation preference stays on-device.
class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController._() : super(ThemeMode.light);
  static final instance = AppearanceController._();
  static const _key = 'taptether.appearance.theme.v1';
  final _storage = const FlutterSecureStorage();

  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _key);
      value = stored == 'dark' ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {
      value = ThemeMode.light;
    }
  }

  Future<void> setDark(bool dark) async {
    await _storage.write(key: _key, value: dark ? 'dark' : 'light');
    value = dark ? ThemeMode.dark : ThemeMode.light;
  }
}

class TapTetherPalette {
  static const teal = Color(0xFF087F73);
  static const ink = Color(0xFF172B35);
  static const canvas = Color(0xFFF2F8FD);
  static const paleTeal = Color(0xFFDFF3ED);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: teal,
      brightness: Brightness.light,
      primary: teal,
      surface: Colors.white,
    );
    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      visualDensity: VisualDensity.compact,
      splashFactory: InkRipple.splashFactory,
      dividerTheme: const DividerThemeData(space: 20, thickness: .7),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(22)))),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 9)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20))))),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white, foregroundColor: ink,
        surfaceTintColor: Colors.transparent, centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: Colors.white, elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(23),
          side: const BorderSide(color: Color(0xFFDCE6E9)),
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(19),
          borderSide: const BorderSide(color: Color(0xFFDCE6E9))),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(19),
          borderSide: const BorderSide(color: teal, width: 1.5)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(19)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
      )),
    );
  }

  static ThemeData dark() => ThemeData(
    brightness: Brightness.dark, useMaterial3: true,
    colorSchemeSeed: const Color(0xFF57E6C2),
    scaffoldBackgroundColor: const Color(0xFF102326),
    appBarTheme: const AppBarTheme(centerTitle: true),
  );
}
