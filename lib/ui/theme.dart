import 'package:material_ui/material_ui.dart';

import '../models/models.dart';

/// Bhagwa (deep saffron). Dark text is used on top of it for readable contrast.
const accent = Color(0xFFFF9933);

/// Darker saffron for the light theme, so saffron text stays readable on white.
const accentOnLight = Color(0xFFCC6600);
const onAccent = Color(0xFF1A1A1A);

ThemeData buildTheme(bool dark) {
  final scheme = dark
      ? const ColorScheme.dark(
          primary: accent,
          onPrimary: onAccent,
          secondary: accent,
          onSecondary: onAccent,
          surface: Color(0xFF212121),
          surfaceContainerLowest: Color(0xFF181818),
          surfaceContainerLow: Color(0xFF1D1D1D),
          surfaceContainer: Color(0xFF262626),
          surfaceContainerHigh: Color(0xFF2C2C2C),
          surfaceContainerHighest: Color(0xFF333333),
          outline: Color(0xFF3A3A3A),
          outlineVariant: Color(0xFF2E2E2E),
          onSurface: Color(0xFFE6E6E6),
          onSurfaceVariant: Color(0xFF9E9E9E),
          error: Color(0xFFFF6B6B),
        )
      : const ColorScheme.light(
          primary: accentOnLight,
          onPrimary: Colors.white,
          secondary: accentOnLight,
          onSecondary: Colors.white,
          surface: Color(0xFFFFFFFF),
          surfaceContainerLowest: Color(0xFFF7F7F7),
          surfaceContainerLow: Color(0xFFF4F4F4),
          surfaceContainer: Color(0xFFF0F0F0),
          surfaceContainerHigh: Color(0xFFE9E9E9),
          surfaceContainerHighest: Color(0xFFE2E2E2),
          outline: Color(0xFFD6D6D6),
          outlineVariant: Color(0xFFE6E6E6),
          onSurface: Color(0xFF212121),
          onSurfaceVariant: Color(0xFF6B6B6B),
          error: Color(0xFFD32F2F),
        );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: dark ? Brightness.dark : Brightness.light);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    dividerColor: scheme.outline,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    visualDensity: VisualDensity.compact,
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: scheme.outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: scheme.outline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: scheme.primary)),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 13),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    popupMenuTheme: PopupMenuThemeData(color: scheme.surfaceContainerHigh, textStyle: TextStyle(fontSize: 13, color: scheme.onSurface)),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainer),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      unselectedLabelStyle: const TextStyle(fontSize: 13),
      tabAlignment: TabAlignment.start,
      dividerColor: scheme.outlineVariant,
    ),
  );
}

Color methodColor(String method) {
  switch (method.toUpperCase()) {
    case 'GET':
      return const Color(0xFF4CC38A);
    case 'POST':
      return const Color(0xFFE6B44C);
    case 'PUT':
      return const Color(0xFF5C9EF0);
    case 'PATCH':
      return const Color(0xFFB18CE0);
    case 'DELETE':
      return const Color(0xFFEF6F61);
    case 'HEAD':
      return const Color(0xFF4CC38A);
    case 'OPTIONS':
      return const Color(0xFFE05CA8);
    default:
      return const Color(0xFF9E9E9E);
  }
}

Color typeColor(RequestType t) {
  switch (t) {
    case RequestType.graphql:
      return const Color(0xFFE535AB);
    case RequestType.grpc:
      return const Color(0xFF4DB6AC);
    case RequestType.websocket:
      return const Color(0xFF7986CB);
    case RequestType.socketio:
      return const Color(0xFF9575CD);
    case RequestType.mqtt:
      return const Color(0xFF81C784);
    case RequestType.sse:
      return const Color(0xFFFFB74D);
    case RequestType.soap:
      return const Color(0xFF4FC3F7);
    case RequestType.kafka:
      return const Color(0xFFE0E0E0);
    case RequestType.http:
      return const Color(0xFF9E9E9E);
  }
}

IconData typeIcon(RequestType t) {
  switch (t) {
    case RequestType.http:
      return Icons.http;
    case RequestType.graphql:
      return Icons.hub_outlined;
    case RequestType.grpc:
      return Icons.settings_ethernet;
    case RequestType.websocket:
      return Icons.swap_horiz;
    case RequestType.socketio:
      return Icons.bolt;
    case RequestType.mqtt:
      return Icons.sensors;
    case RequestType.sse:
      return Icons.stream;
    case RequestType.soap:
      return Icons.code;
    case RequestType.kafka:
      return Icons.view_stream_outlined;
  }
}

Color statusColor(int s) {
  if (s >= 200 && s < 300) return const Color(0xFF4CC38A);
  if (s >= 300 && s < 400) return const Color(0xFF5C9EF0);
  if (s >= 400 && s < 500) return const Color(0xFFE6B44C);
  return const Color(0xFFEF6F61);
}

const monoFamily = 'monospace';
const monoFallback = ['Consolas', 'Menlo', 'DejaVu Sans Mono', 'Courier New'];

TextStyle mono(BuildContext context, {double? size, Color? color}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size ?? 13,
      height: 1.4,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );
