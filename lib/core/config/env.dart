/// Build-time configuration. Values are injected with
/// `flutter run --dart-define-from-file=env/dev.json` so no keys live in code.
///
/// Only the public anon/publishable key belongs here. NEVER put the Supabase
/// service-role key in the app.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured =>
      supabaseUrl.startsWith('https://') &&
      supabaseAnonKey.isNotEmpty &&
      !supabaseUrl.contains('YOUR-') &&
      !supabaseAnonKey.contains('YOUR-');

  /// True when the file was passed but still holds the example placeholders.
  static bool get hasPlaceholders => supabaseUrl.contains('YOUR-') || supabaseAnonKey.contains('YOUR-');
}
