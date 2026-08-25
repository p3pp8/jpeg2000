/* Copyright 2012 Mozilla Foundation
 * Licensed under the Apache License, Version 2.0.
 * Dart port of runk/jpeg2000/src/arithmetic-decoder.js.
 */
import 'dart:typed_data';

final class _QeEntry {
  const _QeEntry(this.qe, this.nmps, this.nlps, this.switchFlag);
  final int qe;
  final int nmps;
  final int nlps;
  final int switchFlag;
}

const List<_QeEntry> _qeTable = <_QeEntry>[
  _QeEntry(0x5601, 1, 1, 1),
  _QeEntry(0x3401, 2, 6, 0),
  _QeEntry(0x1801, 3, 9, 0),
  _QeEntry(0x0ac1, 4, 12, 0),
  _QeEntry(0x0521, 5, 29, 0),
  _QeEntry(0x0221, 38, 33, 0),
  _QeEntry(0x5601, 7, 6, 1),
  _QeEntry(0x5401, 8, 14, 0),
  _QeEntry(0x4801, 9, 14, 0),
  _QeEntry(0x3801, 10, 14, 0),
  _QeEntry(0x3001, 11, 17, 0),
  _QeEntry(0x2401, 12, 18, 0),
  _QeEntry(0x1c01, 13, 20, 0),
  _QeEntry(0x1601, 29, 21, 0),
  _QeEntry(0x5601, 15, 14, 1),
  _QeEntry(0x5401, 16, 14, 0),
  _QeEntry(0x5101, 17, 15, 0),
  _QeEntry(0x4801, 18, 16, 0),
  _QeEntry(0x3801, 19, 17, 0),
  _QeEntry(0x3401, 20, 18, 0),
  _QeEntry(0x3001, 21, 19, 0),
  _QeEntry(0x2801, 22, 19, 0),
  _QeEntry(0x2401, 23, 20, 0),
  _QeEntry(0x2201, 24, 21, 0),
  _QeEntry(0x1c01, 25, 22, 0),
  _QeEntry(0x1801, 26, 23, 0),
  _QeEntry(0x1601, 27, 24, 0),
  _QeEntry(0x1401, 28, 25, 0),
  _QeEntry(0x1201, 29, 26, 0),
  _QeEntry(0x1101, 30, 27, 0),
  _QeEntry(0x0ac1, 31, 28, 0),
  _QeEntry(0x09c1, 32, 29, 0),
  _QeEntry(0x08a1, 33, 30, 0),
  _QeEntry(0x0521, 34, 31, 0),
  _QeEntry(0x0441, 35, 32, 0),
  _QeEntry(0x02a1, 36, 33, 0),
  _QeEntry(0x0221, 37, 34, 0),
  _QeEntry(0x0141, 38, 35, 0),
  _QeEntry(0x0111, 39, 36, 0),
  _QeEntry(0x0085, 40, 37, 0),
  _QeEntry(0x0049, 41, 38, 0),
  _QeEntry(0x0025, 42, 39, 0),
  _QeEntry(0x0015, 43, 40, 0),
  _QeEntry(0x0009, 44, 41, 0),
  _QeEntry(0x0005, 45, 42, 0),
  _QeEntry(0x0001, 45, 43, 0),
  _QeEntry(0x5601, 46, 46, 0),
];

/// QM arithmetic decoder, direct port of the original JavaScript implementation.
final class ArithmeticDecoder {
  ArithmeticDecoder(this.data, int start, this.dataEnd)
      : bp = start,
        chigh = data[start],
        clow = 0,
        ct = 0,
        a = 0 {
    byteIn();
    chigh = ((chigh << 7) & 0xffff) | ((clow >> 9) & 0x7f);
    clow = (clow << 7) & 0xffff;
    ct -= 7;
    a = 0x8000;
  }

  final Uint8List data;
  int bp;
  final int dataEnd;
  int chigh;
  int clow;
  int ct;
  int a;

  void byteIn() {
    var localBp = bp;

    // JavaScript TypedArrays return `undefined` for an out-of-range read.
    // The original decoder relies on that behaviour at the end of an MQ
    // coded segment: `undefined === 0xff` is false and bitwise conversion of
    // `undefined` yields zero. Dart TypedData throws a RangeError instead, so
    // the boundary cases have to be represented explicitly here.
    final current = localBp < dataEnd ? data[localBp] : -1;
    if (current == 0xff) {
      final next = localBp + 1 < dataEnd ? data[localBp + 1] : -1;
      if (next > 0x8f) {
        clow += 0xff00;
        ct = 8;
      } else {
        localBp++;
        final value = localBp < dataEnd ? data[localBp] : 0;
        clow += value << 9;
        ct = 7;
        bp = localBp;
      }
    } else {
      localBp++;
      clow += localBp < dataEnd ? data[localBp] << 8 : 0xff00;
      ct = 8;
      bp = localBp;
    }
    if (clow > 0xffff) {
      chigh += clow >> 16;
      clow &= 0xffff;
    }
  }

  int readBit(Int8List contexts, int pos) {
    var cxIndex = contexts[pos] >> 1;
    var cxMps = contexts[pos] & 1;
    final entry = _qeTable[cxIndex];
    final qe = entry.qe;
    late int d;
    var localA = a - qe;
    if (chigh < qe) {
      if (localA < qe) {
        localA = qe;
        d = cxMps;
        cxIndex = entry.nmps;
      } else {
        localA = qe;
        d = 1 ^ cxMps;
        if (entry.switchFlag == 1) cxMps = d;
        cxIndex = entry.nlps;
      }
    } else {
      chigh -= qe;
      if ((localA & 0x8000) != 0) {
        a = localA;
        return cxMps;
      }
      if (localA < qe) {
        d = 1 ^ cxMps;
        if (entry.switchFlag == 1) cxMps = d;
        cxIndex = entry.nlps;
      } else {
        d = cxMps;
        cxIndex = entry.nmps;
      }
    }
    do {
      if (ct == 0) byteIn();
      localA <<= 1;
      chigh = ((chigh << 1) & 0xffff) | ((clow >> 15) & 1);
      clow = (clow << 1) & 0xffff;
      ct--;
    } while ((localA & 0x8000) == 0);
    a = localA;
    contexts[pos] = (cxIndex << 1) | cxMps;
    return d;
  }
}
