import 'package:flutter/material.dart';

/// Bridge design system — calm, system-grade, Phone Link / KDE Connect grade.
///
/// Principles:
/// - One accent (trustworthy blue), neutrals do the rest. No gradients,
///   no purple glows, no serif display type.
/// - 8pt spacing, 12–20dp radii, 1px slate borders, single soft shadow.
/// - System typography (Roboto / Segoe UI) with tight tracking on titles.
///
/// Field names (`linen`, `clay`, …) are kept stable so existing screens
/// keep compiling — values map to a refined slate + blue palette.
class BridgeColors {
  BridgeColors._();

  // ── Surfaces (light) ──────────────────────────────────────────────
  static const linen = Color(0xFFF8FAFC); // app background (slate-50)
  static const card = Color(0xFFFFFFFF); // cards / sheets
  static const sand = Color(0xFFE2E8F0); // borders (slate-200)
  static const sandSoft = Color(0xFFF1F5F9); // muted fill (slate-100)

  // ── Primary (trustworthy blue) ────────────────────────────────────
  static const clay = Color(0xFF0B57D0);
  static const clayDeep = Color(0xFF0842A0);
  static const claySoft = Color(0xFFE8F0FE);
  static const clayInk = Color(0xFF0842A0);

  // ── Success ───────────────────────────────────────────────────────
  static const sage = Color(0xFF16A34A);
  static const sageDeep = Color(0xFF137333);
  static const sageSoft = Color(0xFFE6F4EA);

  // ── Text ──────────────────────────────────────────────────────────
  static const ink = Color(0xFF0F172A); // slate-900
  static const inkSoft = Color(0xFF475569); // slate-600
  static const muted = Color(0xFF94A3B8); // slate-400

  static const disconnectedDot = Color(0xFFCBD5E1);
  static const creamText = Color(0xFFFFFFFF);
  static const brandCream = Color(0xFFFFFFFF);
  static const qrMat = Color(0xFFFFFFFF);
  static const videoWell = Color(0xFF0B0F14);

  // ── Semantic ──────────────────────────────────────────────────────
  static const warning = Color(0xFFB45309);
  static const warningSoft = Color(0xFFFEF3C7);
  static const error = Color(0xFFB3261E);
  static const errorSoft = Color(0xFFFDECEA);

  // ── Dark mode surfaces ────────────────────────────────────────────
  static const darkBg = Color(0xFF0B1220);
  static const darkCard = Color(0xFF111C30);
  static const darkBorder = Color(0xFF1E2D47);
  static const darkInk = Color(0xFFE6EDF7);
  static const darkInkSoft = Color(0xFF9DB0C7);

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

/// 8pt spacing scale — use instead of magic numbers.
class BridgeSpacing {
  BridgeSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// Radii scale.
class BridgeRadii {
  BridgeRadii._();
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 22;
  static const double pill = 999;
}

/// Single soft shadow — one depth everywhere.
class BridgeShadows {
  BridgeShadows._();

  static const card = <BoxShadow>[
    BoxShadow(color: Color(0x0D0F172A), blurRadius: 12, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x080F172A), blurRadius: 28, offset: Offset(0, 10)),
  ];

  static const pop = <BoxShadow>[
    BoxShadow(color: Color(0x140F172A), blurRadius: 18, offset: Offset(0, 10)),
  ];

  static const none = <BoxShadow>[];
}

/// Restrained motion: quick fades and gentle rises only.
class BridgeMotion {
  BridgeMotion._();

  static const calm = Curves.easeOutCubic;
  static const itemIn = Duration(milliseconds: 180);
  static const panelIn = Duration(milliseconds: 220);
  static const replyExpand = Duration(milliseconds: 200);
  static const copyFade = Duration(milliseconds: 1300);
}

class BridgeText {
  BridgeText._();

  static const statusMain = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
    letterSpacing: -0.4,
    color: BridgeColors.ink,
  );

  static const brand = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: BridgeColors.ink,
  );

  static const panelTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.15,
    color: BridgeColors.ink,
  );

  static const notifTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: BridgeColors.ink,
  );

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
    height: 1.55,
    color: BridgeColors.inkSoft,
  );

  static const button = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    color: BridgeColors.creamText,
  );

  static const badgeCaps = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.9,
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
    fontSize: 12.5,
    height: 1.5,
    color: BridgeColors.inkSoft,
  );

  /// Eyebrow label above sections ("CONTROL YOUR PC").
  static const eyebrow = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
    color: BridgeColors.muted,
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
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: BridgeColors.ink,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: BridgeColors.card,
        indicatorColor: BridgeColors.claySoft,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: BridgeColors.clay);
          }
          return const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: BridgeColors.muted);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: BridgeColors.clay);
          }
          return const IconThemeData(color: BridgeColors.muted);
        }),
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
          elevation: 0,
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return BridgeColors.clayDeep;
            }
            if (states.contains(WidgetState.disabled)) {
              return const Color(0xFFE2E8F0);
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
      chipTheme: const ChipThemeData(
        backgroundColor: BridgeColors.sandSoft,
        labelStyle: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: BridgeColors.inkSoft),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: StadiumBorder(side: BorderSide(color: BridgeColors.sand)),
      ),
      cardTheme: const CardThemeData(
        color: BridgeColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
          side: BorderSide(color: BridgeColors.sand),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: BridgeColors.card,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(22)),
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        showDragHandle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF0F172A),
        contentTextStyle: BridgeText.body.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BridgeColors.clay,
        linearTrackColor: Color(0xFFE2E8F0),
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
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        hintStyle: BridgeText.bodySoft.copyWith(color: BridgeColors.muted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BridgeColors.sand),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BridgeColors.clay, width: 1.6),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: BridgeColors.sand,
        thickness: 1,
        space: 1,
      ),
      iconTheme: const IconThemeData(color: BridgeColors.inkSoft),
      listTileTheme: const ListTileThemeData(
        iconColor: BridgeColors.inkSoft,
        textColor: BridgeColors.ink,
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: BridgeColors.clay,
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF7DACF8),
      onPrimary: const Color(0xFF0B1220),
      primaryContainer: const Color(0xFF1B3A6B),
      onPrimaryContainer: const Color(0xFFDCE8FD),
      surface: BridgeColors.darkBg,
      onSurface: BridgeColors.darkInk,
      surfaceContainerHighest: BridgeColors.darkCard,
      onSurfaceVariant: BridgeColors.darkInkSoft,
      outline: BridgeColors.darkBorder,
      outlineVariant: BridgeColors.darkBorder,
    );
    final light = BridgeTheme.light();
    return light.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: BridgeColors.darkBg,
      appBarTheme: light.appBarTheme.copyWith(
        backgroundColor: BridgeColors.darkBg,
        foregroundColor: BridgeColors.darkInk,
        titleTextStyle: light.appBarTheme.titleTextStyle
            ?.copyWith(color: BridgeColors.darkInk),
      ),
      cardTheme: light.cardTheme.copyWith(color: BridgeColors.darkCard),
      navigationBarTheme: light.navigationBarTheme.copyWith(
        backgroundColor: BridgeColors.darkCard,
        indicatorColor: const Color(0xFF1B3A6B),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF7DACF8));
          }
          return const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: BridgeColors.darkInkSoft);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFF7DACF8));
          }
          return const IconThemeData(color: BridgeColors.darkInkSoft);
        }),
      ),
      dialogTheme: light.dialogTheme.copyWith(
        backgroundColor: BridgeColors.darkCard,
        titleTextStyle: light.dialogTheme.titleTextStyle
            ?.copyWith(color: BridgeColors.darkInk),
        contentTextStyle: BridgeText.body.copyWith(
          color: BridgeColors.darkInkSoft,
        ),
        iconColor: BridgeColors.darkInkSoft,
      ),
      bottomSheetTheme: light.bottomSheetTheme.copyWith(
        backgroundColor: BridgeColors.darkCard,
      ),
      dividerTheme: light.dividerTheme.copyWith(
        color: BridgeColors.darkBorder,
      ),
      iconTheme: const IconThemeData(color: BridgeColors.darkInkSoft),
      listTileTheme: light.listTileTheme.copyWith(
        iconColor: BridgeColors.darkInkSoft,
        textColor: BridgeColors.darkInk,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF7DACF8),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: light.inputDecorationTheme.copyWith(
        fillColor: BridgeColors.darkCard,
        hintStyle: BridgeText.bodySoft.copyWith(
          color: BridgeColors.darkInkSoft,
        ),
      ),
    );
  }
}

/// Shared card container: white surface, 1px border, single soft shadow.
class BridgeCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? color;
  final Border? border;

  const BridgeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.onTap,
    this.color,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? BridgeColors.card,
        border: border ?? Border.all(color: BridgeColors.sand),
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

/// Small uppercase section label — keeps home/settings scannable.
class BridgeEyebrow extends StatelessWidget {
  final String text;
  const BridgeEyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(text.toUpperCase(), style: BridgeText.eyebrow),
    );
  }
}

/// Status dot with optional pulse.
class BridgeDot extends StatelessWidget {
  final Color color;
  final double size;
  const BridgeDot({super.key, required this.color, this.size = 10});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
