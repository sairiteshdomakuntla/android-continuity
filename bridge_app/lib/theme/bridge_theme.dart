import 'package:flutter/material.dart';

/// Bridge "Clay + Linen" design tokens — extracted literally from the
/// confirmed Windows companion app (bridge-agent/src/style.css).
/// Warm boutique aesthetic: linen base, terracotta primary, sage
/// secondary (used sparingly), espresso text, soft warm shadows.
class BridgeColors {
  BridgeColors._();

  static const linen = Color(0xFFF4EEE3);
  static const card = Color(0xFFFCF9F3);
  static const sand = Color(0xFFE5D9C4);
  static const sandSoft = Color(0xFFEDE4D2);

  static const clay = Color(0xFFBC5E36);
  static const clayDeep = Color(0xFF9C4A28);
  static const claySoft = Color(0xFFF3E2D3);
  static const clayInk = Color(0xFF8A3F22);

  static const sage = Color(0xFF6F7F5C);
  static const sageDeep = Color(0xFF57663F);
  static const sageSoft = Color(0xFFE3E7D4);

  static const ink = Color(0xFF2F2620);
  static const inkSoft = Color(0xFF6E6155);
  static const muted = Color(0xFFA29382);

  static const disconnectedDot = Color(0xFFC9BDA9);
  static const creamText = Color(0xFFFDF8EF);
  static const brandCream = Color(0xFFFAF5EA);
  static const qrMat = Color(0xFFFFFDF8);
  static const videoWell = Color(0xFF241D16);

  // Clipboard type-indicator colors (dusty/muted, per Windows).
  static const typeUrl = Color(0xFF557B95);
  static const typeOtp = Color(0xFFA9742B);
  static const typeEmail = Color(0xFF8C6D8C);

  static Color typeColor(String type) {
    switch (type.toLowerCase()) {
      case 'url':
        return typeUrl;
      case 'otp':
        return typeOtp;
      case 'email':
        return typeEmail;
      case 'phone':
        return sageDeep;
      case 'image':
        return clayInk;
      default:
        return inkSoft;
    }
  }
}

/// Soft warm elevation — cards resting on linen. No glow effects.
class BridgeShadows {
  BridgeShadows._();

  static const card = <BoxShadow>[
    BoxShadow(color: Color(0x1A7A5A3A), blurRadius: 30, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x147A5A3A), blurRadius: 6, offset: Offset(0, 2)),
  ];
}

/// Restrained motion: quick fades and gentle rises only.
class BridgeMotion {
  BridgeMotion._();

  static const calm = Curves.easeOut;
  static const itemIn = Duration(milliseconds: 180);
  static const panelIn = Duration(milliseconds: 200);
  static const replyExpand = Duration(milliseconds: 200);
  static const copyFade = Duration(milliseconds: 1300);
}

class BridgeText {
  BridgeText._();

  static const _serif = 'Fraunces';
  static const _sans = 'NunitoSans';

  /// Device name / status hero.
  static const statusMain = TextStyle(
    fontFamily: _serif,
    fontSize: 26,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: BridgeColors.ink,
  );

  static const brand = TextStyle(
    fontFamily: _serif,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: BridgeColors.ink,
  );

  /// Panel headings ("Phone Notifications", "Clipboard History").
  static const panelTitle = TextStyle(
    fontFamily: _serif,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: BridgeColors.ink,
  );

  /// Notification titles.
  static const notifTitle = TextStyle(
    fontFamily: _serif,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: BridgeColors.ink,
  );

  /// File names in progress cards.
  static const fileName = TextStyle(
    fontFamily: _serif,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: BridgeColors.ink,
  );

  static const body = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    height: 1.5,
    color: BridgeColors.ink,
  );

  static const bodySoft = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    height: 1.5,
    color: BridgeColors.inkSoft,
  );

  static const button = TextStyle(
    fontFamily: _sans,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: BridgeColors.creamText,
  );

  /// Small caps badges ("ENCRYPTED · AES-256-GCM").
  static const badgeCaps = TextStyle(
    fontFamily: _sans,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
    color: BridgeColors.sageDeep,
  );

  static const count = TextStyle(
    fontFamily: _sans,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: BridgeColors.inkSoft,
  );

  static const timestamp = TextStyle(
    fontFamily: _sans,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: BridgeColors.muted,
  );
}

class BridgeTheme {
  BridgeTheme._();

  static const _sans = 'NunitoSans';

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: BridgeColors.clay,
      brightness: Brightness.light,
    ).copyWith(
      primary: BridgeColors.clay,
      onPrimary: BridgeColors.creamText,
      primaryContainer: BridgeColors.claySoft,
      onPrimaryContainer: BridgeColors.clayInk,
      secondary: BridgeColors.sage,
      onSecondary: BridgeColors.creamText,
      secondaryContainer: BridgeColors.sageSoft,
      onSecondaryContainer: BridgeColors.sageDeep,
      surface: BridgeColors.linen,
      onSurface: BridgeColors.ink,
      surfaceContainerHighest: BridgeColors.card,
      onSurfaceVariant: BridgeColors.inkSoft,
      outline: BridgeColors.sand,
      outlineVariant: BridgeColors.sand,
      error: BridgeColors.clayInk,
      onError: BridgeColors.creamText,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: BridgeColors.linen,
      fontFamily: _sans,
      textTheme: const TextTheme(
        bodyMedium: BridgeText.body,
        bodySmall: BridgeText.bodySoft,
        labelLarge: BridgeText.button,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: BridgeColors.clay,
          foregroundColor: BridgeColors.creamText,
          textStyle: BridgeText.button,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return BridgeColors.clayInk;
            }
            if (states.contains(WidgetState.hovered)) {
              return BridgeColors.clayDeep;
            }
            return BridgeColors.clay;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BridgeColors.ink,
          textStyle: BridgeText.button.copyWith(color: BridgeColors.ink),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          side: const BorderSide(color: BridgeColors.sand),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BridgeColors.inkSoft,
          textStyle: const TextStyle(
            fontFamily: _sans,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      cardTheme: const CardThemeData(
        color: BridgeColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: BridgeColors.sand),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: BridgeColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: BridgeColors.sand),
        ),
        titleTextStyle: TextStyle(
          fontFamily: 'Fraunces',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: BridgeColors.ink,
        ),
        contentTextStyle: BridgeText.body,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: BridgeColors.ink,
        contentTextStyle: BridgeText.body.copyWith(color: BridgeColors.creamText),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BridgeColors.clay,
        linearTrackColor: BridgeColors.sandSoft,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BridgeColors.linen,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: BridgeText.bodySoft.copyWith(color: BridgeColors.muted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BridgeColors.sand),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BridgeColors.clay),
        ),
      ),
      iconTheme: const IconThemeData(color: BridgeColors.inkSoft),
    );
  }
}

/// Shared card container: warm card, 1px sand border, soft warm shadow.
class BridgeCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const BridgeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: BridgeColors.card,
        border: Border.all(color: BridgeColors.sand),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: BridgeShadows.card,
      ),
      child: child,
    );
  }
}
