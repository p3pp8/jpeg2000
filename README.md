# jpeg2000

This plugin helps with decoding JPEG 2000 code stream. All in vanilla Dart with no dependencies. Typings included.

```dart
import 'dart:typed_data';

import 'jpeg2000/jpx.dart';

void main() {
  final codestream = Uint8List.fromList([
    0xff, 0x4f, 0xff, 0x51, 0x00, 0x29, 0x00, 0x00,
    // ...
  ]);

  final jpx = JpxImage();

  jpx.parse(codestream);

  print('width: ${jpx.width}');
  print('height: ${jpx.height}');
  print('components: ${jpx.componentsCount}');
  print('tiles:');
  print(jpx.tiles);
}

```
\
**NOTE**: This library has been successfully used to decompress the face image contained in the Italian Electronic Identity Card (CIE), which is compressed using JPEG 2000.

# Credits
### This plugin is a direct port in pure Dart language of [runk/jpeg2000](https://github.com/runk/jpeg2000) javascript module.