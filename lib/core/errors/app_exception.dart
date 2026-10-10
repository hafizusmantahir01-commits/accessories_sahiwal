import 'package:supabase_flutter/supabase_flutter.dart';

/// User-facing error with a safe message (no internals leaked).
class AppException implements Exception {
  const AppException(this.message, {this.kind = AppErrorKind.general});

  final String message;
  final AppErrorKind kind;

  bool get isPrivateLocked => kind == AppErrorKind.privateLocked;

  /// Converts any thrown object into a safe, readable message.
  factory AppException.from(Object error) {
    if (error is AppException) return error;
    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('invalid login') || msg.contains('invalid credentials')) {
        return const AppException('Email or password is incorrect.');
      }
      if (msg.contains('rate') || msg.contains('too many')) {
        return const AppException('Too many attempts. Please wait a few minutes and try again.');
      }
      return const AppException('Sign-in failed. Please try again.', kind: AppErrorKind.auth);
    }
    if (error is PostgrestException) {
      final msg = error.message;
      if (msg.startsWith('PRIVATE_LOCKED')) {
        return const AppException(
          'The Owner Private Area is locked. Unlock it to continue.',
          kind: AppErrorKind.privateLocked,
        );
      }
      if (msg.startsWith('PRIVATE_SECRET_NOT_SET')) {
        return const AppException('Set a private password first.', kind: AppErrorKind.validation);
      }
      if (msg.startsWith('BELOW_COST:')) {
        return AppException(msg.substring('BELOW_COST:'.length).trim(), kind: AppErrorKind.belowCost);
      }
      for (final prefix in const ['PRODUCT_IN_USE:', 'INSUFFICIENT_STOCK:', 'ALREADY_SOLD:']) {
        if (msg.startsWith(prefix)) {
          return AppException(msg.substring(prefix.length).trim(), kind: AppErrorKind.validation);
        }
      }
      if (msg.startsWith('SHORTFALL:')) {
        return AppException(msg.substring('SHORTFALL:'.length).trim(), kind: AppErrorKind.validation);
      }
      switch (error.code) {
        case '42501':
          return AppException(
            msg.contains('Not authorised') || msg.contains('Owner access required')
                ? 'You do not have permission to do this.'
                : msg,
            kind: AppErrorKind.forbidden,
          );
        case '23505':
          if (msg.contains('products_code_uq')) {
            return const AppException('This product code already exists.', kind: AppErrorKind.validation);
          }
          if (msg.contains('products_barcode_uq')) {
            return const AppException('This barcode is already used by another product.',
                kind: AppErrorKind.validation);
          }
          if (msg.contains('categories_name_uq')) {
            return const AppException('A category with this name already exists.',
                kind: AppErrorKind.validation);
          }
          if (msg.contains('suppliers_name_uq')) {
            return const AppException('A supplier with this name already exists.',
                kind: AppErrorKind.validation);
          }
          return const AppException('This record already exists.', kind: AppErrorKind.validation);
        case '23503':
          return const AppException('This record is used elsewhere and cannot be removed. Archive it instead.',
              kind: AppErrorKind.validation);
        case '23514':
        case '22023':
        case '22P02':
        case '55000':
        case 'P0002':
        case '54000':
        case '28P01':
          // Messages raised by our own database functions are written for users.
          return AppException(msg, kind: AppErrorKind.validation);
        case '42P17':
        case 'PGRST301':
          return const AppException('Your session has expired. Please sign in again.',
              kind: AppErrorKind.auth);
      }
      return const AppException('The server could not complete this request. Please try again.');
    }
    if (error is StorageException) {
      final status = error.statusCode ?? '';
      if (status == '413' || error.message.toLowerCase().contains('size')) {
        return const AppException('Photo is too large (maximum 5 MB).', kind: AppErrorKind.validation);
      }
      return const AppException('Photo upload failed. Please try again.');
    }
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('ClientException') ||
        text.contains('Failed host lookup') ||
        text.contains('XMLHttpRequest')) {
      return const AppException('No internet connection. Check your connection and try again.',
          kind: AppErrorKind.network);
    }
    return const AppException('Something went wrong. Please try again.');
  }

  @override
  String toString() => message;
}

enum AppErrorKind { general, auth, forbidden, privateLocked, validation, network, belowCost }
