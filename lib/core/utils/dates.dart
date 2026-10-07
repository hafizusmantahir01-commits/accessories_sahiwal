import 'package:intl/intl.dart';

/// Business timezone is Asia/Karachi (UTC+05:00, no daylight saving).
/// Timestamps are stored in UTC by the database and displayed in local business time.
abstract final class BizTime {
  static const offset = Duration(hours: 5);

  static DateTime toKarachi(DateTime value) => value.toUtc().add(offset);

  static DateTime? parse(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  /// Today's date in Karachi, independent of the device timezone.
  static DateTime today() {
    final k = toKarachi(DateTime.now());
    return DateTime(k.year, k.month, k.day);
  }

  static String dateTime(Object? value) {
    final d = value is DateTime ? value : parse(value);
    if (d == null) return '—';
    return DateFormat('dd MMM yyyy, hh:mm a').format(toKarachi(d));
  }

  static String date(Object? value) {
    if (value == null) return '—';
    // Plain dates ("2026-10-04") have no timezone; format as-is.
    if (value is String && value.length == 10) {
      final d = DateTime.tryParse(value);
      return d == null ? value : DateFormat('dd MMM yyyy').format(d);
    }
    final d = value is DateTime ? value : parse(value);
    if (d == null) return '—';
    return DateFormat('dd MMM yyyy').format(d.isUtc ? toKarachi(d) : d);
  }

  static String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
}
