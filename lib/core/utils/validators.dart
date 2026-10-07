import 'money.dart';

/// Form validators returning a message or null.
abstract final class Validators {
  static String? required(String? v, [String label = 'This field']) =>
      (v == null || v.trim().isEmpty) ? '$label is required' : null;

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email is required';
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim()) ? null : 'Enter a valid email';
  }

  static String? password(String? v, {int min = 8}) {
    if (v == null || v.isEmpty) return 'Password is required';
    if (v.length < min) return 'Use at least $min characters';
    if (v.length > 72) return 'Use at most 72 characters';
    return null;
  }

  /// Positive whole-piece quantity.
  static String? quantity(String? v, {bool allowZero = false}) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Quantity is required';
    final n = int.tryParse(t);
    if (n == null) return 'Whole numbers only';
    if (n < 0 || (!allowZero && n == 0)) return allowZero ? 'Cannot be negative' : 'Must be at least 1';
    if (n > 1000000) return 'Too large';
    return null;
  }

  /// Non-negative money with at most 2 decimals.
  static String? money(String? v, {bool required = true}) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return required ? 'Amount is required' : null;
    return Money.tryParseInput(t) == null ? 'Enter a valid amount (max 2 decimals)' : null;
  }

  /// Product code: letters, digits, . _ / - (max 40). Blank = auto-generate.
  static String? productCode(String? v) {
    final t = v?.trim().toUpperCase() ?? '';
    if (t.isEmpty) return null;
    return RegExp(r'^[A-Z0-9][A-Z0-9._/-]{0,39}$').hasMatch(t)
        ? null
        : 'Use letters, numbers, - . _ / (max 40)';
  }
}
