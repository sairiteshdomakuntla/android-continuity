import 'package:flutter/material.dart';

/// Bridge design system — professional, system-grade tokens.
///
/// Intentionally neutral and product-like (Phone Link / Samsung Flow grade):
/// neutral surfaces, a single trustworthy blue primary, semantic status
/// colors, system typography (no serif), subtle Material elevation.
///
/// NOTE: field names are kept stable (`linen`, `clay`, …) so existing
/// screens keep compiling — values are remapped to the new palette.
class BridgeColors {
  BridgeColors._();

  // Surfaces
  static const linen = Color(0xFFF3F4F6); // app background
  static const card = Color(0xFFFFFFFF); // cards / sheets
  static const sand = Color(0xFFE5E7EB); // borders
  static const sandSoft = Color(0xFFF1F5F9); // pressed / muted fill

  // Primary (trustworthy blue)
  static const clay = Color(0xFF0B57D0);
  static const clayDeep = Color(0xFF0842A0);
  static const claySoft = Color(0xFFE8F0FE);
  static const clayInk = Color(0xFF0842A0);

  // Success
  static const sage = Color(0xFF16A34A);
  static const sageDeep = Color(0xFF137333);
  static const sageSoft = Color(0xFFE6F4EA);

  // Text
  static const ink = Color(0xFF111827);
  static const inkSoft = Color(0xFF4B5563);
  static const muted = Color(0xFF9AA0A6);

  static const disconnectedDot = Color(0xFFD1D5DB);
  static const creamText = Color(0xFFFFFFFF);
  static const brandCream = Color(0xFFFFFFFF);
  static const qrMat = Color(0xFFFFFFFF);
  static const videoWell = Color(0xFF0B0D12);

  // Extras used by new UI
  static const warning = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFEF3C7);
  static const error = Color(0xFFB3261E);
  static const errorSoft = Color(0xFFFDECEA);

  // Clipboard type-indicator colors (muted professional set).
  static const typeUrl = Color(0xFF0B57D0);
  static const typeOtp = Color(0xFFB45309);
  static const typeEmail = Color(0xFF6D28D9);

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

/// Subtle system elevation — never boutique glows.
class BridgeShadows {
  BridgeShadows._();

  static const card = <BoxShadow>[
    BoxShadow(color: Color(0x0F111827), blurRadius: 10, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A111827), blurRadius: 24, offset: Offset(0, 8)),
  ];

  static const pop = <BoxShadow>[
    BoxShadow(color: Color(0x14111827), blurRadius: 16, offset: Offset(0, 8)),
  ];
}

/// Restrained motion: quick fades and gentle rises only.
class BridgeMotion {
  BridgeMotion._();

  static const calm = Curves.easeOutCubic;
  static const itemIn = Duration(milliseconds: 180);
  static const panelIn = Duration(milliseconds: 200);
  static const replyExpand = Duration(milliseconds: 200);
  static const copyFade = Duration(milliseconds: 1300);
}

class BridgeText {
  BridgeText._();

  /// Large status / screen titles. System font, tight tracking.
  static const statusMain = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
    letterSpacing: -0.3,
    color: BridgeColors.ink,
  );

  static const brand = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: BridgeColors.ink,
  );

  /// Section headings.
  static const panelTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    color: BridgeColors.ink,
  );

  /// List item titles.
  static const notifTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: BridgeColors.ink,
  );

  /// File names in progress cards.
  static const fileName = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: BridgeColors.ink,
  );

  static const body = TextStyle(
    fontSize: 14,
    height: 1.5,
    color: BridgeColors.ink,
  );

  static const bodySoft = TextStyle(
    fontSize: 13,
    height: 1.5,
    color: BridgeColors.inkSoft,
  );

  static const button = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    color: BridgeColors.creamText,
  );

  /// Small caps badges ("ENCRYPTED · AES-256-GCM").
  static const badgeCaps = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: BridgeColors.sageDeep,
  );

  static const count = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: BridgeColors.inkSoft,
  );

  static const timestamp = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: BridgeColors.muted,
  );

  static const caption = TextStyle(
    fontSize: 12,
    height: 1.45,
    color: BridgeColors.inkSoft,
  );
}

class BridgeTheme {
  BridgeTheme._();

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: BridgeColors.clay,
      brightness: Brightness.light,
    ).copyWith(
      primary: BridgeColors.clay,
      onPrimary: Colors.white,
      primaryContainer: BridgeColors.claySoft,
      onPrimaryContainer: BridgeColors.clayInk,
      secondary: BridgeColors.inkSoft,
      onSecondary: Colors.white,
      secondaryContainer: BridgeColors.sandSoft,
      onSecondaryContainer: BridgeColors.ink,
      surface: BridgeColors.linen,
      onSurface: BridgeColors.ink,
      surfaceContainerHighest: BridgeColors.card,
      onSurfaceVariant: BridgeColors.inkSoft,
      outline: BridgeColors.sand,
      outlineVariant: BridgeColors.sand,
      error: BridgeColors.error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: BridgeColors.linen,
      appBarTheme: const AppBarTheme(
        backgroundColor: BridgeColors.linen,
        foregroundColor: BridgeColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: BridgeColors.ink,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: BridgeColors.card,
        indicatorColor: BridgeColors.claySoft,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: BridgeColors.clay,
          foregroundColor: Colors.white,
          textStyle: BridgeText.button,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return BridgeColors.clayDeep;
            }
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFFE5E7EB);
            }
            return BridgeColors.clay;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return BridgeColors.muted;
            }
            return Colors.white;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BridgeColors.ink,
          backgroundColor: BridgeColors.card,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          side: const BorderSide(color: BridgeColors.sand),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BridgeColors.clay,
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      cardTheme: const CardThemeData(
        color: BridgeColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: BridgeColors.sand),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: BridgeColors.card,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
          color: BridgeColors.ink,
        ),
        contentTextStyle: BridgeText.body,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: BridgeColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF1F2937),
        contentTextStyle: BridgeText.body.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BridgeColors.clay,
        linearTrackColor: Color(0xFFE5E7EB),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? BridgeColors.clay : null),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BridgeColors.card,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: BridgeText.bodySoft.copyWith(color: BridgeColors.muted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BridgeColors.sand),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BridgeColors.clay, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: BridgeColors.sand,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: BridgeColors.inkSoft),
    );
  }
}

/// Shared card container: white surface, 1px border, subtle shadow.
class BridgeCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  const BridgeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: BridgeColors.card,
        border: Border.all(color: BridgeColors.sand),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: BridgeShadows.card,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: card,
    );
  }
}
