import 'package:flutter/material.dart';

/// Brand theme taken from the Accessories Sahiwal logo:
/// deep navy text, steel-blue accent and a gold ring.
abstract final class AppTheme {
  static const navy = Color(0xFF0B1F3F); // logo lettering
  static const steel = Color(0xFF3F5B8C); // logo "A" / chevron
  static const gold = Color(0xFFB08D3C); // logo ring
  static const goldLight = Color(0xFFE2C77E);
  static const blue = steel; // kept for older code
  static const success = Color(0xFF15803D);
  static const warning = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);

  /// Banner / login background: navy → steel.
  static const heroColors = [Color(0xFF06142C), navy, steel];

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: navy,
      primary: navy,
      secondary: gold,
      tertiary: steel,
      surface: Colors.white,
      brightness: Brightness.light,
    );
    return _base(scheme).copyWith(scaffoldBackgroundColor: const Color(0xFFF6F5F1));
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: navy, secondary: gold, brightness: Brightness.dark);
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.primary,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(color: scheme.primary, fontSize: 22, fontWeight: FontWeight.w700),
        shape: const Border(bottom: BorderSide(color: Color(0x33B08D3C))), // thin gold line
      ),
      // Raised cards and buttons with soft navy shadows = 3D depth everywhere.
      cardTheme: CardThemeData(
        elevation: 3,
        shadowColor: scheme.primary.withValues(alpha: 0.30),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: gold.withValues(alpha: 0.18)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: gold, width: 2),
        ),
        floatingLabelStyle: const TextStyle(color: navy, fontWeight: FontWeight.w600),
        filled: true,
        fillColor: Colors.white,
        isDense: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: navy,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          elevation: 4,
          shadowColor: navy.withValues(alpha: 0.5),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: navy,
          side: const BorderSide(color: gold, width: 1.2),
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: steel)),
      chipTheme: ChipThemeData(
        selectedColor: gold.withValues(alpha: 0.22),
        side: BorderSide(color: gold.withValues(alpha: 0.45)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? gold.withValues(alpha: 0.22) : null,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: gold.withValues(alpha: 0.6))),
        ),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 10, iconColor: steel),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 8,
        indicatorColor: gold.withValues(alpha: 0.28),
        shadowColor: scheme.primary.withValues(alpha: 0.4),
        surfaceTintColor: Colors.transparent,
      ),
      navigationRailTheme: NavigationRailThemeData(
        indicatorColor: gold.withValues(alpha: 0.28),
        selectedIconTheme: const IconThemeData(color: navy),
        selectedLabelTextStyle: const TextStyle(color: navy, fontWeight: FontWeight.w700),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        elevation: 6,
        highlightElevation: 2,
        backgroundColor: navy,
        foregroundColor: Colors.white,
        shape: StadiumBorder(side: BorderSide(color: gold, width: 1.5)),
      ),
      dividerTheme: DividerThemeData(color: gold.withValues(alpha: 0.25)),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: gold),
    );
  }
}