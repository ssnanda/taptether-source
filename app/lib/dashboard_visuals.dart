import 'package:flutter/material.dart';

/// Shared visual language for the TapTether home and remote.
///// UI-only widgets: no changes to LAN, security or control behavior.
class TapTetherDashboardVisuals {
  static const navy = Color(0xFF142D52);
  static const teal = Color(0xFF058F92);
  static const blue = Color(0xFF3381F6);
  static const mint = Color(0xFF18BDA5);
  static const orange = Color(0xFFF6A443);

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static BoxDecoration pageBackground(BuildContext context) {
    if (dark(context)) {
      return const BoxDecoration(color: Color(0xFF102326));
    }
    return const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFF4FAFF), Color(0xFFEDF7FD), Color(0xFFF8FCFF)],
    ));
  }

  static Widget iconTile(IconData icon, Color start, Color end,
      {double size = 52}) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .32),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [start, end],
        ),
        boxShadow: [BoxShadow(
          color: end.withValues(alpha: .23),
          blurRadius: 12, offset: const Offset(0, 5),
        )],
      ),
      child: Icon(icon, size: size * .52, color: Colors.white),
    );
  }

  static Widget deviceSummary(BuildContext context, {
    required int computers, required int televisions, required int xbox,
  }) {
    final ink = dark(context) ? Colors.white : navy;
    Widget count(IconData icon, Color color, String count, String label) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 5),
          Text(count, style: TextStyle(
              color: ink, fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(color: ink.withValues(alpha: .8),
              fontSize: 12)),
        ]);
    return Container(
      key: const ValueKey('dashboard-device-counts'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: dark(context) ? const Color(0xFF203B43) : Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: dark(context)
            ? Colors.white12 : const Color(0xFFD6EBF7)),
        boxShadow: dark(context) ? [] : [BoxShadow(
          color: const Color(0xFF5191BB).withValues(alpha: .10),
          blurRadius: 17, offset: const Offset(0, 6),
        )],
      ),
      child: Wrap(
        spacing: 15, runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        children: [
          count(Icons.computer_rounded, mint, '$computers', 'computers'),
          count(Icons.tv_rounded, blue, '$televisions', 'TVs'),
          count(Icons.sports_esports_rounded, orange, '$xbox', 'Xbox'),
        ],
      ),
    );
  }

  static Widget applianceCard(BuildContext context, {
    required Key key,
    required String name,
    required String status,
    required String id,
    required IconData icon,
    required Color accent,
    required Color accentEnd,
    required VoidCallback onTap,
    required List<Widget> actions,
  }) {
    final isDark = dark(context);
    final tint = accent.withValues(alpha: isDark ? .20 : .11);
    final endTint = accentEnd.withValues(alpha: isDark ? .12 : .08);
    final textColor = isDark ? Colors.white : navy;
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      color: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(25),
        side: BorderSide(color: accent.withValues(alpha: .19)),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1A3439), const Color(0xFF22383E)]
              : [Colors.white, Color.lerp(Colors.white, tint, .64)!,
                  Color.lerp(Colors.white, endTint, .9)!],
        )),
        child: Stack(children: [
          Positioned(right: 22, bottom: -21, child: IgnorePointer(
            child: Icon(icon, size: 105,
                color: accent.withValues(alpha: isDark ? .07 : .08)),
          )),
          ListTile(
            minVerticalPadding: 14,
            contentPadding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
            leading: iconTile(icon, accent, accentEnd),
            title: Text(name, maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w800,
                  fontSize: 17, letterSpacing: -.3)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(status,
                key: ValueKey('lg-thinq-status-$id'),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5,
                  color: textColor.withValues(alpha: .70))),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
            onTap: onTap,
          ),
        ]),
      ),
    );
  }

  static Widget actionRow(BuildContext context, {
    required IconData icon,
    required Color accent,
    required String label,
    required VoidCallback onTap,
  }) {
    final isDark = dark(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      color: isDark ? const Color(0xFF203A41) : Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(21),
        side: BorderSide(color: isDark ? Colors.white12 :
            const Color(0xFFDEECF7))),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14,
            vertical: 5),
        leading: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? .24 : .12),
            borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: accent, size: 22),
        ),
        title: Text(label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : navy,
            )),
        trailing: const Icon(Icons.chevron_right_rounded, size: 23),
        onTap: onTap,
      ),
    );
  }

  static Widget connectedDeviceHeader(BuildContext context, {
    required String name, required bool offline,
  }) {
    final isDark = dark(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF203B43) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: isDark
            ? Colors.white12 : const Color(0xFFE0EBF7)),
      ),
      child: Row(children: [
        Container(
          height: 9, width: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: offline ? Colors.redAccent : const Color(0xFF14B86C)),
        ),
        const SizedBox(width: 12),
        Icon(Icons.laptop_rounded, color: isDark
            ? const Color(0xFF4CDECA) : teal, size: 24),
        const SizedBox(width: 10),
        Expanded(child: Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : navy,
            ))),
      ]),
    );
  }

  static BoxDecoration trackpadDecoration(BuildContext context,
      {required bool immersive}) {
    final isDark = dark(context);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(immersive ? 0 : 25),
      gradient: LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: isDark
            ? [const Color(0xFF144C57), const Color(0xFF1B6D73)]
            : [const Color(0xFFBCF1FB), const Color(0xFFCBFAEB),
                const Color(0xFF99EAE0)],
      ),
      border: immersive ? null : Border.all(
        color: teal.withValues(alpha: .26), width: 1.4,
      ),
    );
  }

  static Widget trackpadHint(BuildContext context) {
    final ink = dark(context) ? Colors.white70 : const Color(0xFF277E8A);
    return IgnorePointer(child: CustomPaint(
      painter: _TapTetherRings(ink.withValues(alpha: .12)),
      child: Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_rounded, color: ink, size: 46),
          const SizedBox(height: 14),
          Text('Tap and move to control your computer',
              style: TextStyle(fontSize: 12.5, color: ink,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
        ],
      )),
    ));
  }
}

class _TapTetherRings extends CustomPainter {
  _TapTetherRings(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final center = Offset(size.width / 2, size.height / 2);
    for (final radius in [88.0, 140.0, 195.0, 250.0]) {
      canvas.drawCircle(center, radius, paint);
    }
  }
  @override
  bool shouldRepaint(_TapTetherRings oldDelegate) =>
      oldDelegate.color != color;
}
