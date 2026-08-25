import 'dart:typed_data';

/// Integer-safe equivalent of ceil(log2(x)) for the positive integer values
/// used by the JPEG 2000 decoder. Avoids floating-point rounding at powers of 2.
int log2Ceil(num x) {
  if (x <= 0) return 0;
  final integer = x.ceil();
  var value = integer - 1;
  var result = 0;
  while (value > 0) {
    value >>= 1;
    result++;
  }
  return result;
}

int readUint16(Uint8List data, int offset) =>
    ByteData.sublistView(data).getUint16(offset, Endian.big);

int readUint32(Uint8List data, int offset) =>
    ByteData.sublistView(data).getUint32(offset, Endian.big);
