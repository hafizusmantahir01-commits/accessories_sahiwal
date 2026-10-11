import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Gives a generated file to the user: on a phone the share sheet opens
/// (save to Files / Drive / WhatsApp), in the browser it is downloaded.
Future<void> shareFile(Uint8List bytes, {required String fileName, required String mimeType}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: mimeType, name: fileName)],
      fileNameOverrides: [fileName],
      subject: fileName,
    ),
  );
}
