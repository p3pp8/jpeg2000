# jpeg2000

[![pub package](https://img.shields.io/pub/v/jpeg2000.svg)](https://pub.dev/packages/jpeg2000)
[![license](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

A **pure Dart JPEG 2000 / JPX decoder** with no runtime dependencies.

The package decodes JPEG 2000 data directly from a `Uint8List` and exposes the decoded image as one or more RGBA tiles. It supports both raw JPEG 2000 codestreams and JP2 containers containing JPEG 2000 image data.

This library is useful when JPEG 2000 decoding is required in a Dart or Flutter application without relying on native codecs or platform-specific libraries.

> **CIE use case:** this library has been successfully used to decompress the face image contained in the Italian Electronic Identity Card (CIE), whose biometric image is encoded using JPEG 2000.

## Features

* Pure Dart implementation.
* No runtime dependencies.
* Supports raw JPEG 2000 codestreams.
* Supports JPEG 2000 data embedded in JP2 containers.
* Exposes image dimensions and component count.
* Decodes image data into RGBA `Uint8List` buffers.
* Supports tiled JPEG 2000 images.
* Provides image property parsing without requiring a complete image decode.
* Suitable for both Dart and Flutter applications.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  jpeg2000: ^0.1.1
```

Then run:

```bash
dart pub get
```

Or, for Flutter projects:

```bash
flutter pub get
```

## Usage

Import the public package API:

```dart
import 'dart:typed_data';

import 'package:jpeg2000/jpeg2000.dart';
```

Create a `JpxImage` and parse the JPEG 2000 bytes:

```dart
final Uint8List data = ...;

final image = JpxImage();
image.parse(data);

print('width: ${image.width}');
print('height: ${image.height}');
print('components: ${image.componentsCount}');
print('bits per component: ${image.bitsPerComponent}');
```

After parsing, the decoded image data is available through `tiles`:

```dart
for (final tile in image.tiles) {
  print('tile: ${tile.width}x${tile.height}');
  print('position: ${tile.left}, ${tile.top}');
  print('RGBA bytes: ${tile.items.length}');
}
```

## Complete example

```dart
import 'dart:typed_data';

import 'package:jpeg2000/jpeg2000.dart';

void main() {
  // Replace this with the bytes of a JPEG 2000 image.
  final data = Uint8List.fromList(<int>[
    // JPEG 2000 data...
  ]);

  final image = JpxImage();
  image.parse(data);

  print('Image: ${image.width} x ${image.height}');
  print('Components: ${image.componentsCount}');
  print('Tiles: ${image.tiles.length}');

  for (final tile in image.tiles) {
    print(
      'Tile ${tile.left},${tile.top} '
      '${tile.width}x${tile.height} '
      '(${tile.items.length} RGBA bytes)',
    );
  }
}
```

A runnable example is also available in the repository under `example/main.dart`.

## Input formats

`JpxImage.parse` accepts JPEG 2000 data in two formats.

### Raw JPEG 2000 codestream

A raw JPEG 2000 codestream starts with the `SOC` marker:

```text
FF 4F
```

This is useful when the JPEG 2000 codestream has already been extracted from another binary structure or container.

A typical codestream contains markers such as:

```text
FF 4F ... FF 51 ... FF 90 ... FF 93 ... FF D9
```

### JP2 container

The parser can also process a JP2 container and automatically locate the `jp2c` box containing the JPEG 2000 codestream.

This means that, when a complete JP2 file is already available in memory, callers do not need to manually extract the codestream before decoding it.

## Decoded image data

The decoded image is exposed as a list of `JpxTile` objects.

Each tile contains:

| Property | Type        | Description                                      |
| -------- | ----------- | ------------------------------------------------ |
| `width`  | `int`       | Tile width in pixels.                            |
| `height` | `int`       | Tile height in pixels.                           |
| `left`   | `int`       | Horizontal position of the tile.                 |
| `top`    | `int`       | Vertical position of the tile.                   |
| `items`  | `Uint8List` | Decoded pixels in RGBA order, 4 bytes per pixel. |

For a tile containing `width × height` pixels, the pixel buffer normally contains:

```text
width × height × 4 bytes
```

The four bytes for each pixel are:

```text
R, G, B, A
```

If the source image contains multiple JPEG 2000 tiles, the decoded image is represented by multiple `JpxTile` instances.

## Image properties without full decoding

`JpxImage` also provides `parseImageProperties`, which can read basic image information from a `JpxByteStream` without decoding the complete image.

The method populates:

* `width`
* `height`
* `componentsCount`
* `bitsPerComponent`

This can be useful when only image metadata is required.

## Error handling

Invalid or unsupported JPEG 2000 data can result in a `JpxError`.

```dart
try {
  final image = JpxImage();
  image.parse(data);
} on JpxError catch (error) {
  print('JPEG 2000 decoding failed: $error');
}
```

The decoder also exposes:

```dart
image.failOnCorruptedImage
```

which can be used to control corrupted-image handling during decoding.

## Flutter

This package does not depend on Flutter APIs and can therefore be used directly in Flutter applications.

The decoder returns raw RGBA pixel data. Converting that data into a Flutter `ui.Image`, a PNG, or another displayable image format is intentionally left to the application.

This keeps the package:

* platform-independent;
* dependency-free;
* usable outside Flutter.

## Italian Electronic Identity Card (CIE)

JPEG 2000 is used by the Italian Electronic Identity Card (CIE) for the biometric face image.

This package can be used after extracting the JPEG 2000 or JP2 image data from the relevant CIE data group.

The package itself does **not**:

* read NFC cards;
* perform CIE authentication;
* parse CIE DG files;
* extract JPEG 2000 data from CIE structures.

Its responsibility is limited to decoding JPEG 2000 image data.

## API

Import the public API with:

```dart
import 'package:jpeg2000/jpeg2000.dart';
```

### `JpxImage`

The main JPEG 2000 decoder.

Important members:

* `parse(Uint8List data)` — parses and decodes JPEG 2000 or JP2 data.
* `parseImageProperties(JpxByteStream stream)` — reads basic image properties from a stream.
* `width` — decoded image width.
* `height` — decoded image height.
* `componentsCount` — number of image components.
* `bitsPerComponent` — bits per component reported by the decoder.
* `tiles` — decoded `JpxTile` objects.
* `failOnCorruptedImage` — controls corrupted-image handling.

### `JpxTile`

Represents a decoded image tile.

Its `items` property contains the decoded pixels in RGBA format.

### `JpxError`

Exception thrown when the decoder encounters invalid or unsupported JPEG 2000 data.

### `JpxByteStream`

Minimal stream interface used by `parseImageProperties`.

## Compatibility

The package currently supports:

```yaml
environment:
  sdk: ">=3.0.0 <4.0.0"
```

It can therefore be used in pure Dart applications and Flutter projects whose Dart SDK satisfies this constraint.

## License

This project is distributed under the **Apache License 2.0**.

See the `LICENSE` file for the complete license text.

## Credits and attribution

This project is a direct port to pure Dart of the `runk/jpeg2000` JavaScript module.

The JPEG 2000 algorithms, marker handling, and packet progression logic follow the original implementation as closely as practical in Dart.

The source also contains material derived from the Mozilla Foundation's JPEG 2000 implementation and is distributed under the Apache License 2.0.

Original project:

* `runk/jpeg2000`

## Contributing

Issues and pull requests are welcome.

Before submitting a change, please ensure that the package still passes the Dart analyzer and its tests.

## Repository

Source code:

`https://github.com/p3pp8/jpeg2000`
