import 'dart:typed_data';

/// Detects an image type from its bytes (not from the file name),
/// so renamed or spoofed files are rejected.
enum ImageKind {
  jpeg('jpg', 'image/jpeg'),
  png('png', 'image/png'),
  webp('webp', 'image/webp');

  const ImageKind(this.extension, this.mimeType);
  final String extension;
  final String mimeType;

  static const maxBytes = 5 * 1024 * 1024;

  static ImageKind? detect(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return ImageKind.jpeg;
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return ImageKind.png;
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) { // WEBP
      return ImageKind.webp;
    }
    return null;
  }
}
