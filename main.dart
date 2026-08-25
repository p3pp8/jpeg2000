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
