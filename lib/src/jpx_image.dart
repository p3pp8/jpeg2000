/// Decodes JPEG 2000 and JP2 images.
///
/// [JpxImage] accepts raw JPEG 2000 codestreams as well as JP2 containers.
/// Decoded image data is exposed through [tiles] as RGBA pixel buffers.
///
/// The decoder is implemented entirely in Dart and has no runtime
/// dependencies.
import 'dart:math' as math;
import 'dart:typed_data';

import 'arithmetic_decoder.dart';
import 'core_utils.dart';

class JpxError implements Exception {
  JpxError(String message) : message = 'JPX error: $message';
  final String message;
  @override
  String toString() => message;
}

class JpxTile {
  const JpxTile({
    required this.height,
    required this.width,
    required this.top,
    required this.left,
    required this.items,
  });

  final int height;
  final int width;
  final int top;
  final int left;
  final Uint8List items;
}

/// Minimal stream contract used by [JpxImage.parseImageProperties].
abstract interface class JpxByteStream {
  int getByte();
  void skip(int count);
  int getInt32();
  int getUint16();
}

void _warn(Object? message) {}
void _info(Object? message) {}

void _setSparse(List<dynamic> list, int index, dynamic value) {
  while (list.length <= index) {
    list.add(null);
  }
  list[index] = value;
}

Map<String, dynamic> _m(dynamic value) => value as Map<String, dynamic>;
List<dynamic> _l(dynamic value) => value as List<dynamic>;
int _i(dynamic value) => value as int;
bool _b(dynamic value) => value as bool;

int _clamp8(num value) {
  if (value.isNaN) return 0;
  final n = value.truncate();
  if (n < 0) return 0;
  if (n > 255) return 255;
  return n;
}

/// Decodes JPEG 2000 and JP2 images.
///
/// [JpxImage] accepts raw JPEG 2000 codestreams as well as JP2 containers.
/// Decoded image data is exposed through [tiles] as RGBA pixel buffers.
///
/// The decoder is implemented entirely in Dart and has no runtime
/// dependencies.
class JpxImage {
  /// Creates a JPEG 2000 image decoder.
  JpxImage();

  /// Whether decoding should fail immediately when corrupted image data
  /// is detected.
  ///
  /// When `false`, the decoder attempts to recover from supported
  /// forms of corrupted input.
  bool failOnCorruptedImage = false;

  /// Width of the decoded image in pixels.
  int width = 0;

  /// Height of the decoded image in pixels.
  int height = 0;

  /// Number of components in the decoded image.
  int componentsCount = 0;

  /// Number of bits used by each image component.
  int bitsPerComponent = 8;

  /// Decoded image tiles.
  ///
  /// Each tile contains RGBA pixel data in its [JpxTile.items] buffer.
  List<JpxTile> tiles = <JpxTile>[];

  static const Map<String, int> _subbandsGainLog2 = <String, int>{
    'LL': 0,
    'LH': 1,
    'HL': 1,
    'HH': 2,
  };

  /// Parses and decodes JPEG 2000 or JP2 image data.
  ///
  /// [data] may contain either a raw JPEG 2000 codestream or a complete
  /// JP2 container.
  ///
  /// On successful decoding, [width], [height], [componentsCount], and
  /// [tiles] contain information about the decoded image.
  ///
  /// Throws [JpxError] when the input is invalid or contains an
  /// unsupported JPEG 2000 feature.
  void parse(Uint8List data) {
    if (data.length < 2) {
      throw JpxError('Invalid data');
    }
    final head = readUint16(data, 0);
    if (head == 0xff4f) {
      parseCodestream(data, 0, data.length);
      return;
    }

    var position = 0;
    final length = data.length;
    while (position < length) {
      if (position + 8 > length) {
        throw JpxError('Invalid box field size');
      }
      var headerSize = 8;
      var lbox = readUint32(data, position);
      final tbox = readUint32(data, position + 4);
      position += headerSize;
      if (lbox == 1) {
        if (position + 8 > length) {
          throw JpxError('Invalid box field size');
        }
        lbox = readUint32(data, position) * 4294967296 +
            readUint32(data, position + 4);
        position += 8;
        headerSize += 8;
      }
      if (lbox == 0) {
        lbox = length - position + headerSize;
      }
      if (lbox < headerSize) {
        throw JpxError('Invalid box field size');
      }
      final dataLength = lbox - headerSize;
      var jumpDataLength = true;
      switch (tbox) {
        case 0x6a703268: // jp2h
          jumpDataLength = false;
          break;
        case 0x636f6c72: // colr
          final method = data[position];
          if (method == 1) {
            final colorspace = readUint32(data, position + 3);
            switch (colorspace) {
              case 16:
              case 17:
              case 18:
                break;
              default:
                _warn('Unknown colorspace $colorspace');
            }
          } else if (method == 2) {
            _info('ICC profile not supported');
          }
          break;
        case 0x6a703263: // jp2c
          parseCodestream(data, position, position + dataLength);
          break;
        case 0x6a502020: // jP
          if (readUint32(data, position) != 0x0d0a870a) {
            _warn('Invalid JP2 signature');
          }
          break;
        case 0x6a501a1a:
        case 0x66747970: // ftyp
        case 0x72726571: // rreq
        case 0x72657320: // res
        case 0x69686472: // ihdr
          break;
        default:
          final headerType = String.fromCharCodes(<int>[
            (tbox >> 24) & 0xff,
            (tbox >> 16) & 0xff,
            (tbox >> 8) & 0xff,
            tbox & 0xff,
          ]);
          _warn('Unsupported header type $tbox ($headerType)');
      }
      if (jumpDataLength) {
        position += dataLength;
      }
    }
  }

  /// Reads basic image properties from a JPEG 2000 byte stream.
  ///
  /// Unlike [parse], this method does not decode the image pixels.
  /// It reads the JPEG 2000 size information and updates [width],
  /// [height], [componentsCount], and [bitsPerComponent].
  ///
  /// Throws [JpxError] when the stream does not contain a JPEG 2000
  /// size marker.
  void parseImageProperties(JpxByteStream stream) {
    var newByte = stream.getByte();
    while (newByte >= 0) {
      final oldByte = newByte;
      newByte = stream.getByte();
      final code = (oldByte << 8) | newByte;
      if (code == 0xff51) {
        stream.skip(4);
        final xsiz = stream.getInt32() & 0xffffffff;
        final ysiz = stream.getInt32() & 0xffffffff;
        final xOsiz = stream.getInt32() & 0xffffffff;
        final yOsiz = stream.getInt32() & 0xffffffff;
        stream.skip(16);
        final csiz = stream.getUint16();
        width = xsiz - xOsiz;
        height = ysiz - yOsiz;
        componentsCount = csiz;
        bitsPerComponent = 8;
        return;
      }
    }
    throw JpxError('No size marker found in JPX stream');
  }

  /// Parses a JPEG 2000 codestream contained in [data].
  ///
  /// The codestream is read from [start] up to [end].
  ///
  /// This method is normally invoked internally by [parse] when the
  /// input contains either a raw JPEG 2000 codestream or the `jp2c`
  /// box of a JP2 container.
  ///
  /// Throws [JpxError] when the codestream is invalid or contains
  /// unsupported JPEG 2000 features.
  void parseCodestream(Uint8List data, int start, int end) {
    final context = <String, dynamic>{};
    var doNotRecover = false;
    try {
      var position = start;
      while (position + 1 < end) {
        final code = readUint16(data, position);
        position += 2;
        var length = 0;
        switch (code) {
          case 0xff4f: // SOC
            context['mainHeader'] = true;
            break;
          case 0xffd9: // EOC
            break;
          case 0xff51: // SIZ
            length = readUint16(data, position);
            final siz = <String, dynamic>{
              'Xsiz': readUint32(data, position + 4),
              'Ysiz': readUint32(data, position + 8),
              'XOsiz': readUint32(data, position + 12),
              'YOsiz': readUint32(data, position + 16),
              'XTsiz': readUint32(data, position + 20),
              'YTsiz': readUint32(data, position + 24),
              'XTOsiz': readUint32(data, position + 28),
              'YTOsiz': readUint32(data, position + 32),
            };
            final count = readUint16(data, position + 36);
            siz['Csiz'] = count;
            final components = <dynamic>[];
            var j = position + 38;
            for (var c = 0; c < count; c++) {
              final component = <String, dynamic>{
                'precision': (data[j] & 0x7f) + 1,
                'isSigned': (data[j] & 0x80) != 0,
                'XRsiz': data[j + 1],
                'YRsiz': data[j + 2],
              };
              j += 3;
              _calculateComponentDimensions(component, siz);
              components.add(component);
            }
            context['SIZ'] = siz;
            context['components'] = components;
            _calculateTileGrids(context, components);
            context['QCC'] = <dynamic>[];
            context['COC'] = <dynamic>[];
            break;
          case 0xff5c: // QCD
            length = readUint16(data, position);
            final qcd = _parseQuantization(
              data,
              position,
              length,
              null,
              context,
            );
            if (context['mainHeader'] == true) {
              context['QCD'] = qcd;
            } else {
              final currentTile = _m(context['currentTile']);
              currentTile['QCD'] = qcd;
              currentTile['QCC'] = <dynamic>[];
            }
            break;
          case 0xff5d: // QCC
            length = readUint16(data, position);
            var j = position + 2;
            final siz = _m(context['SIZ']);
            late int cqcc;
            if (_i(siz['Csiz']) < 257) {
              cqcc = data[j++];
            } else {
              cqcc = readUint16(data, j);
              j += 2;
            }
            final qcc = _parseQuantization(data, position, length, j, context);
            if (context['mainHeader'] == true) {
              _setSparse(_l(context['QCC']), cqcc, qcc);
            } else {
              final currentTile = _m(context['currentTile']);
              _setSparse(_l(currentTile['QCC']), cqcc, qcc);
            }
            break;
          case 0xff52: // COD
            length = readUint16(data, position);
            final cod = <String, dynamic>{};
            var j = position + 2;
            final scod = data[j++];
            cod['entropyCoderWithCustomPrecincts'] = (scod & 1) != 0;
            cod['sopMarkerUsed'] = (scod & 2) != 0;
            cod['ephMarkerUsed'] = (scod & 4) != 0;
            cod['progressionOrder'] = data[j++];
            cod['layersCount'] = readUint16(data, j);
            j += 2;
            cod['multipleComponentTransform'] = data[j++];
            cod['decompositionLevelsCount'] = data[j++];
            cod['xcb'] = (data[j++] & 0xf) + 2;
            cod['ycb'] = (data[j++] & 0xf) + 2;
            final blockStyle = data[j++];
            cod['selectiveArithmeticCodingBypass'] = (blockStyle & 1) != 0;
            cod['resetContextProbabilities'] = (blockStyle & 2) != 0;
            cod['terminationOnEachCodingPass'] = (blockStyle & 4) != 0;
            cod['verticallyStripe'] = (blockStyle & 8) != 0;
            cod['predictableTermination'] = (blockStyle & 16) != 0;
            cod['segmentationSymbolUsed'] = (blockStyle & 32) != 0;
            cod['reversibleTransformation'] = data[j++];
            if (_b(cod['entropyCoderWithCustomPrecincts'])) {
              final precinctsSizes = <dynamic>[];
              while (j < length + position) {
                final precinctsSize = data[j++];
                precinctsSizes.add(<String, dynamic>{
                  'PPx': precinctsSize & 0xf,
                  'PPy': precinctsSize >> 4,
                });
              }
              cod['precinctsSizes'] = precinctsSizes;
            }
            final unsupported = <String>[];
            if (_b(cod['selectiveArithmeticCodingBypass'])) {
              unsupported.add('selectiveArithmeticCodingBypass');
            }
            if (_b(cod['resetContextProbabilities'])) {
              unsupported.add('resetContextProbabilities');
            }
            if (_b(cod['terminationOnEachCodingPass'])) {
              unsupported.add('terminationOnEachCodingPass');
            }
            if (_b(cod['verticallyStripe'])) {
              unsupported.add('verticallyStripe');
            }
            if (_b(cod['predictableTermination'])) {
              unsupported.add('predictableTermination');
            }
            if (unsupported.isNotEmpty) {
              doNotRecover = true;
              throw JpxError(
                'Unsupported COD options (${unsupported.join(', ')})',
              );
            }
            if (context['mainHeader'] == true) {
              context['COD'] = cod;
            } else {
              final currentTile = _m(context['currentTile']);
              currentTile['COD'] = cod;
              currentTile['COC'] = <dynamic>[];
            }
            break;
          case 0xff90: // SOT
            length = readUint16(data, position);
            final tile = <String, dynamic>{};
            tile['index'] = readUint16(data, position + 2);
            tile['length'] = readUint32(data, position + 4);
            tile['dataEnd'] = _i(tile['length']) + position - 2;
            tile['partIndex'] = data[position + 8];
            tile['partsCount'] = data[position + 9];
            context['mainHeader'] = false;
            if (_i(tile['partIndex']) == 0) {
              tile['COD'] = context['COD'];
              tile['COC'] = List<dynamic>.from(_l(context['COC']));
              tile['QCD'] = context['QCD'];
              tile['QCC'] = List<dynamic>.from(_l(context['QCC']));
            }
            context['currentTile'] = tile;
            break;
          case 0xff93: // SOD
            final tile = _m(context['currentTile']);
            if (_i(tile['partIndex']) == 0) {
              _initializeTile(context, _i(tile['index']));
              _buildPackets(context);
            }
            length = _i(tile['dataEnd']) - position;
            _parseTilePackets(context, data, position, length);
            break;
          case 0xff53: // COC
            doNotRecover = true;
            throw JpxError('Codestream code 0xFF53 (COC) is not implemented.');
          case 0xff55:
          case 0xff57:
          case 0xff58:
          case 0xff64:
            length = readUint16(data, position);
            break;
          default:
            throw JpxError(
              'Unknown codestream code: ${code.toRadixString(16)}',
            );
        }
        position += length;
      }
    } catch (e) {
      if (doNotRecover || failOnCorruptedImage) {
        final message = e is JpxError
            ? e.message.replaceFirst('JPX error: ', '')
            : e.toString();
        throw JpxError(message);
      }
      _warn('JPX: Trying to recover from: "$e".');
    }

    tiles = _transformComponents(context);
    final siz = _m(context['SIZ']);
    width = _i(siz['Xsiz']) - _i(siz['XOsiz']);
    height = _i(siz['Ysiz']) - _i(siz['YOsiz']);
    componentsCount = _i(siz['Csiz']);
  }

  Map<String, dynamic> _parseQuantization(
    Uint8List data,
    int position,
    int length,
    int? start,
    Map<String, dynamic> context,
  ) {
    final q = <String, dynamic>{};
    var j = start ?? position + 2;
    final sqcd = data[j++];
    late int spqcdSize;
    late bool scalarExpounded;
    switch (sqcd & 0x1f) {
      case 0:
        spqcdSize = 8;
        scalarExpounded = true;
        break;
      case 1:
        spqcdSize = 16;
        scalarExpounded = false;
        break;
      case 2:
        spqcdSize = 16;
        scalarExpounded = true;
        break;
      default:
        throw JpxError('Invalid SQcd value $sqcd');
    }
    q['noQuantization'] = spqcdSize == 8;
    q['scalarExpounded'] = scalarExpounded;
    q['guardBits'] = sqcd >> 5;
    final spqcds = <dynamic>[];
    while (j < length + position) {
      final spqcd = <String, dynamic>{};
      if (spqcdSize == 8) {
        spqcd['epsilon'] = data[j++] >> 3;
        spqcd['mu'] = 0;
      } else {
        spqcd['epsilon'] = data[j] >> 3;
        spqcd['mu'] = ((data[j] & 0x7) << 8) | data[j + 1];
        j += 2;
      }
      spqcds.add(spqcd);
    }
    q['SPqcds'] = spqcds;
    return q;
  }

  void _calculateComponentDimensions(
    Map<String, dynamic> component,
    Map<String, dynamic> siz,
  ) {
    component['x0'] = (_i(siz['XOsiz']) / _i(component['XRsiz'])).ceil();
    component['x1'] = (_i(siz['Xsiz']) / _i(component['XRsiz'])).ceil();
    component['y0'] = (_i(siz['YOsiz']) / _i(component['YRsiz'])).ceil();
    component['y1'] = (_i(siz['Ysiz']) / _i(component['YRsiz'])).ceil();
    component['width'] = _i(component['x1']) - _i(component['x0']);
    component['height'] = _i(component['y1']) - _i(component['y0']);
  }

  void _calculateTileGrids(
    Map<String, dynamic> context,
    List<dynamic> components,
  ) {
    final siz = _m(context['SIZ']);
    final tiles = <dynamic>[];
    final numXtiles =
        ((_i(siz['Xsiz']) - _i(siz['XTOsiz'])) / _i(siz['XTsiz'])).ceil();
    final numYtiles =
        ((_i(siz['Ysiz']) - _i(siz['YTOsiz'])) / _i(siz['YTsiz'])).ceil();
    for (var q = 0; q < numYtiles; q++) {
      for (var p = 0; p < numXtiles; p++) {
        final tile = <String, dynamic>{
          'tx0': math.max(
            _i(siz['XTOsiz']) + p * _i(siz['XTsiz']),
            _i(siz['XOsiz']),
          ),
          'ty0': math.max(
            _i(siz['YTOsiz']) + q * _i(siz['YTsiz']),
            _i(siz['YOsiz']),
          ),
          'tx1': math.min(
            _i(siz['XTOsiz']) + (p + 1) * _i(siz['XTsiz']),
            _i(siz['Xsiz']),
          ),
          'ty1': math.min(
            _i(siz['YTOsiz']) + (q + 1) * _i(siz['YTsiz']),
            _i(siz['Ysiz']),
          ),
          'components': <dynamic>[],
        };
        tile['width'] = _i(tile['tx1']) - _i(tile['tx0']);
        tile['height'] = _i(tile['ty1']) - _i(tile['ty0']);
        tiles.add(tile);
      }
    }
    context['tiles'] = tiles;
    for (var i = 0; i < _i(siz['Csiz']); i++) {
      final component = _m(components[i]);
      for (var j = 0; j < tiles.length; j++) {
        final tile = _m(tiles[j]);
        final tc = <String, dynamic>{};
        tc['tcx0'] = (_i(tile['tx0']) / _i(component['XRsiz'])).ceil();
        tc['tcy0'] = (_i(tile['ty0']) / _i(component['YRsiz'])).ceil();
        tc['tcx1'] = (_i(tile['tx1']) / _i(component['XRsiz'])).ceil();
        tc['tcy1'] = (_i(tile['ty1']) / _i(component['YRsiz'])).ceil();
        tc['width'] = _i(tc['tcx1']) - _i(tc['tcx0']);
        tc['height'] = _i(tc['tcy1']) - _i(tc['tcy0']);
        _setSparse(_l(tile['components']), i, tc);
      }
    }
  }

  Map<String, dynamic> _getBlocksDimensions(
    Map<String, dynamic> context,
    Map<String, dynamic> component,
    int r,
  ) {
    final cod = _m(component['codingStyleParameters']);
    final result = <String, dynamic>{};
    if (!_b(cod['entropyCoderWithCustomPrecincts'])) {
      result['PPx'] = 15;
      result['PPy'] = 15;
    } else {
      final ps = _m(_l(cod['precinctsSizes'])[r]);
      result['PPx'] = ps['PPx'];
      result['PPy'] = ps['PPy'];
    }
    result['xcb_'] = r > 0
        ? math.min(_i(cod['xcb']), _i(result['PPx']) - 1)
        : math.min(_i(cod['xcb']), _i(result['PPx']));
    result['ycb_'] = r > 0
        ? math.min(_i(cod['ycb']), _i(result['PPy']) - 1)
        : math.min(_i(cod['ycb']), _i(result['PPy']));
    return result;
  }

  void _buildPrecincts(
    Map<String, dynamic> context,
    Map<String, dynamic> resolution,
    Map<String, dynamic> dimensions,
  ) {
    final precinctWidth = 1 << _i(dimensions['PPx']);
    final precinctHeight = 1 << _i(dimensions['PPy']);
    final isZeroRes = _i(resolution['resLevel']) == 0;
    final precinctWidthInSubband =
        1 << (_i(dimensions['PPx']) + (isZeroRes ? 0 : -1));
    final precinctHeightInSubband =
        1 << (_i(dimensions['PPy']) + (isZeroRes ? 0 : -1));
    final numprecinctswide = _i(resolution['trx1']) > _i(resolution['trx0'])
        ? (_i(resolution['trx1']) / precinctWidth).ceil() -
            (_i(resolution['trx0']) / precinctWidth).floor()
        : 0;
    final numprecinctshigh = _i(resolution['try1']) > _i(resolution['try0'])
        ? (_i(resolution['try1']) / precinctHeight).ceil() -
            (_i(resolution['try0']) / precinctHeight).floor()
        : 0;
    resolution['precinctParameters'] = <String, dynamic>{
      'precinctWidth': precinctWidth,
      'precinctHeight': precinctHeight,
      'numprecinctswide': numprecinctswide,
      'numprecinctshigh': numprecinctshigh,
      'numprecincts': numprecinctswide * numprecinctshigh,
      'precinctWidthInSubband': precinctWidthInSubband,
      'precinctHeightInSubband': precinctHeightInSubband,
    };
  }

  void _buildCodeblocks(
    Map<String, dynamic> context,
    Map<String, dynamic> subband,
    Map<String, dynamic> dimensions,
  ) {
    final xcb = _i(dimensions['xcb_']);
    final ycb = _i(dimensions['ycb_']);
    final codeblockWidth = 1 << xcb;
    final codeblockHeight = 1 << ycb;
    final cbx0 = _i(subband['tbx0']) >> xcb;
    final cby0 = _i(subband['tby0']) >> ycb;
    final cbx1 = (_i(subband['tbx1']) + codeblockWidth - 1) >> xcb;
    final cby1 = (_i(subband['tby1']) + codeblockHeight - 1) >> ycb;
    final precinctParameters = _m(
      _m(subband['resolution'])['precinctParameters'],
    );
    final codeblocks = <dynamic>[];
    final precincts = <dynamic>[];

    for (var j = cby0; j < cby1; j++) {
      for (var i = cbx0; i < cbx1; i++) {
        final codeblock = <String, dynamic>{
          'cbx': i,
          'cby': j,
          'tbx0': codeblockWidth * i,
          'tby0': codeblockHeight * j,
          'tbx1': codeblockWidth * (i + 1),
          'tby1': codeblockHeight * (j + 1),
        };
        codeblock['tbx0_'] = math.max(
          _i(subband['tbx0']),
          _i(codeblock['tbx0']),
        );
        codeblock['tby0_'] = math.max(
          _i(subband['tby0']),
          _i(codeblock['tby0']),
        );
        codeblock['tbx1_'] = math.min(
          _i(subband['tbx1']),
          _i(codeblock['tbx1']),
        );
        codeblock['tby1_'] = math.min(
          _i(subband['tby1']),
          _i(codeblock['tby1']),
        );
        final pi = ((_i(codeblock['tbx0_']) - _i(subband['tbx0'])) /
                _i(precinctParameters['precinctWidthInSubband']))
            .floor();
        final pj = ((_i(codeblock['tby0_']) - _i(subband['tby0'])) /
                _i(precinctParameters['precinctHeightInSubband']))
            .floor();
        final precinctNumber =
            pi + pj * _i(precinctParameters['numprecinctswide']);
        codeblock['precinctNumber'] = precinctNumber;
        codeblock['subbandType'] = subband['type'];
        codeblock['Lblock'] = 3;
        if (_i(codeblock['tbx1_']) <= _i(codeblock['tbx0_']) ||
            _i(codeblock['tby1_']) <= _i(codeblock['tby0_'])) {
          continue;
        }
        codeblocks.add(codeblock);
        Map<String, dynamic> precinct;
        if (precinctNumber < precincts.length &&
            precincts[precinctNumber] != null) {
          precinct = _m(precincts[precinctNumber]);
          if (i < _i(precinct['cbxMin'])) {
            precinct['cbxMin'] = i;
          } else if (i > _i(precinct['cbxMax'])) {
            precinct['cbxMax'] = i;
          }
          // Intentionally mirrors runk/jpeg2000 exactly, including the
          // original cbxMin assignment in this branch.
          if (j < _i(precinct['cbyMin'])) {
            precinct['cbxMin'] = j;
          } else if (j > _i(precinct['cbyMax'])) {
            precinct['cbyMax'] = j;
          }
        } else {
          precinct = <String, dynamic>{
            'cbxMin': i,
            'cbyMin': j,
            'cbxMax': i,
            'cbyMax': j,
          };
          _setSparse(precincts, precinctNumber, precinct);
        }
        codeblock['precinct'] = precinct;
      }
    }
    subband['codeblockParameters'] = <String, dynamic>{
      'codeblockWidth': xcb,
      'codeblockHeight': ycb,
      'numcodeblockwide': cbx1 - cbx0 + 1,
      'numcodeblockhigh': cby1 - cby0 + 1,
    };
    subband['codeblocks'] = codeblocks;
    subband['precincts'] = precincts;
  }

  void _buildPackets(Map<String, dynamic> context) {
    final siz = _m(context['SIZ']);
    final tileIndex = _i(_m(context['currentTile'])['index']);
    final tile = _m(_l(context['tiles'])[tileIndex]);
    final componentsCount = _i(siz['Csiz']);
    for (var c = 0; c < componentsCount; c++) {
      final component = _m(_l(tile['components'])[c]);
      final decompositionLevelsCount = _i(
        _m(component['codingStyleParameters'])['decompositionLevelsCount'],
      );
      final resolutions = <dynamic>[];
      final subbands = <dynamic>[];
      for (var r = 0; r <= decompositionLevelsCount; r++) {
        final blocksDimensions = _getBlocksDimensions(context, component, r);
        final resolution = <String, dynamic>{};
        final scale = 1 << (decompositionLevelsCount - r);
        resolution['trx0'] = (_i(component['tcx0']) / scale).ceil();
        resolution['try0'] = (_i(component['tcy0']) / scale).ceil();
        resolution['trx1'] = (_i(component['tcx1']) / scale).ceil();
        resolution['try1'] = (_i(component['tcy1']) / scale).ceil();
        resolution['resLevel'] = r;
        _buildPrecincts(context, resolution, blocksDimensions);
        resolutions.add(resolution);
        if (r == 0) {
          final subband = <String, dynamic>{
            'type': 'LL',
            'tbx0': (_i(component['tcx0']) / scale).ceil(),
            'tby0': (_i(component['tcy0']) / scale).ceil(),
            'tbx1': (_i(component['tcx1']) / scale).ceil(),
            'tby1': (_i(component['tcy1']) / scale).ceil(),
            'resolution': resolution,
          };
          _buildCodeblocks(context, subband, blocksDimensions);
          subbands.add(subband);
          resolution['subbands'] = <dynamic>[subband];
        } else {
          final bscale = 1 << (decompositionLevelsCount - r + 1);
          final resolutionSubbands = <dynamic>[];

          Map<String, dynamic> makeSubband(
            String type,
            num xOffset,
            num yOffset,
          ) {
            final subband = <String, dynamic>{
              'type': type,
              'tbx0': (_i(component['tcx0']) / bscale + xOffset).ceil(),
              'tby0': (_i(component['tcy0']) / bscale + yOffset).ceil(),
              'tbx1': (_i(component['tcx1']) / bscale + xOffset).ceil(),
              'tby1': (_i(component['tcy1']) / bscale + yOffset).ceil(),
              'resolution': resolution,
            };
            _buildCodeblocks(context, subband, blocksDimensions);
            subbands.add(subband);
            resolutionSubbands.add(subband);
            return subband;
          }

          makeSubband('HL', -0.5, 0);
          makeSubband('LH', 0, -0.5);
          makeSubband('HH', -0.5, -0.5);
          resolution['subbands'] = resolutionSubbands;
        }
      }
      component['resolutions'] = resolutions;
      component['subbands'] = subbands;
    }

    final progressionOrder = _i(
      _m(tile['codingStyleDefaultParameters'])['progressionOrder'],
    );
    switch (progressionOrder) {
      case 0:
        tile['packetsIterator'] = _LrcpIterator(context);
        break;
      case 1:
        tile['packetsIterator'] = _RlcpIterator(context);
        break;
      case 2:
        tile['packetsIterator'] = _RpclIterator(context);
        break;
      case 3:
        tile['packetsIterator'] = _PcrlIterator(context);
        break;
      case 4:
        tile['packetsIterator'] = _CprlIterator(context);
        break;
      default:
        throw JpxError('Unsupported progression order $progressionOrder');
    }
  }

  int _parseTilePackets(
    Map<String, dynamic> context,
    Uint8List data,
    int offset,
    int dataLength,
  ) {
    var position = 0;
    var buffer = 0;
    var bufferSize = 0;
    var skipNextBit = false;

    int readBits(int count) {
      while (bufferSize < count) {
        if (offset + position >= data.length) {
          throw JpxError('Unexpected end of packet data');
        }
        final b = data[offset + position];
        position++;
        if (skipNextBit) {
          buffer = (buffer << 7) | b;
          bufferSize += 7;
          skipNextBit = false;
        } else {
          buffer = (buffer << 8) | b;
          bufferSize += 8;
        }
        if (b == 0xff) skipNextBit = true;
      }
      bufferSize -= count;
      return (buffer >> bufferSize) & ((1 << count) - 1);
    }

    void skipBytes(int count) {
      position += count;
    }

    bool skipMarkerIfEqual(int value) {
      final absolute = offset + position;
      if (position > 0 &&
          absolute < data.length &&
          data[absolute - 1] == 0xff &&
          data[absolute] == value) {
        skipBytes(1);
        return true;
      }
      if (absolute + 1 < data.length &&
          data[absolute] == 0xff &&
          data[absolute + 1] == value) {
        skipBytes(2);
        return true;
      }
      return false;
    }

    void alignToByte() {
      bufferSize = 0;
      if (skipNextBit) {
        position++;
        skipNextBit = false;
      }
    }

    int readCodingpasses() {
      if (readBits(1) == 0) return 1;
      if (readBits(1) == 0) return 2;
      var value = readBits(2);
      if (value < 3) return value + 3;
      value = readBits(5);
      if (value < 31) return value + 6;
      value = readBits(7);
      return value + 37;
    }

    final tileIndex = _i(_m(context['currentTile'])['index']);
    final tile = _m(_l(context['tiles'])[tileIndex]);
    final cod = _m(context['COD']);
    final sopMarkerUsed = _b(cod['sopMarkerUsed']);
    final ephMarkerUsed = _b(cod['ephMarkerUsed']);
    final packetsIterator = tile['packetsIterator'] as _PacketIterator;

    while (position < dataLength) {
      alignToByte();
      if (sopMarkerUsed && skipMarkerIfEqual(0x91)) {
        skipBytes(4);
      }
      final packet = packetsIterator.nextPacket();
      if (readBits(1) == 0) continue;
      final layerNumber = _i(packet['layerNumber']);
      final queue = <Map<String, dynamic>>[];
      for (final raw in _l(packet['codeblocks'])) {
        final codeblock = _m(raw);
        var precinct = _m(codeblock['precinct']);
        final codeblockColumn = _i(codeblock['cbx']) - _i(precinct['cbxMin']);
        final codeblockRow = _i(codeblock['cby']) - _i(precinct['cbyMin']);
        var codeblockIncluded = false;
        var firstTimeInclusion = false;
        if (codeblock.containsKey('included')) {
          codeblockIncluded = readBits(1) != 0;
        } else {
          precinct = _m(codeblock['precinct']);
          late _InclusionTree inclusionTree;
          late _TagTree zeroBitPlanesTree;
          if (precinct['inclusionTree'] != null) {
            inclusionTree = precinct['inclusionTree'] as _InclusionTree;
            zeroBitPlanesTree = precinct['zeroBitPlanesTree'] as _TagTree;
          } else {
            final treeWidth =
                _i(precinct['cbxMax']) - _i(precinct['cbxMin']) + 1;
            final treeHeight =
                _i(precinct['cbyMax']) - _i(precinct['cbyMin']) + 1;
            inclusionTree = _InclusionTree(treeWidth, treeHeight, layerNumber);
            zeroBitPlanesTree = _TagTree(treeWidth, treeHeight);
            precinct['inclusionTree'] = inclusionTree;
            precinct['zeroBitPlanesTree'] = zeroBitPlanesTree;
          }
          if (inclusionTree.reset(codeblockColumn, codeblockRow, layerNumber)) {
            while (true) {
              if (readBits(1) != 0) {
                final valueReady = !inclusionTree.nextLevel();
                if (valueReady) {
                  codeblock['included'] = true;
                  codeblockIncluded = true;
                  firstTimeInclusion = true;
                  break;
                }
              } else {
                inclusionTree.incrementValue(layerNumber);
                break;
              }
            }
          }
        }
        if (!codeblockIncluded) continue;
        if (firstTimeInclusion) {
          final zeroBitPlanesTree = precinct['zeroBitPlanesTree'] as _TagTree;
          zeroBitPlanesTree.reset(codeblockColumn, codeblockRow);
          while (true) {
            if (readBits(1) != 0) {
              if (!zeroBitPlanesTree.nextLevel()) break;
            } else {
              zeroBitPlanesTree.incrementValue();
            }
          }
          codeblock['zeroBitPlanes'] = zeroBitPlanesTree.value;
        }
        final codingpasses = readCodingpasses();
        while (readBits(1) != 0) {
          codeblock['Lblock'] = _i(codeblock['Lblock']) + 1;
        }
        final codingpassesLog2 = log2Ceil(codingpasses);
        final bits = (codingpasses < (1 << codingpassesLog2)
                ? codingpassesLog2 - 1
                : codingpassesLog2) +
            _i(codeblock['Lblock']);
        final codedDataLength = readBits(bits);
        queue.add(<String, dynamic>{
          'codeblock': codeblock,
          'codingpasses': codingpasses,
          'dataLength': codedDataLength,
        });
      }
      alignToByte();
      if (ephMarkerUsed) skipMarkerIfEqual(0x92);
      while (queue.isNotEmpty) {
        final packetItem = queue.removeAt(0);
        final codeblock = _m(packetItem['codeblock']);
        final codeblockData =
            (codeblock['data'] ??= <dynamic>[]) as List<dynamic>;
        codeblockData.add(<String, dynamic>{
          'data': data,
          'start': offset + position,
          'end': offset + position + _i(packetItem['dataLength']),
          'codingpasses': packetItem['codingpasses'],
        });
        position += _i(packetItem['dataLength']);
      }
    }
    return position;
  }

  void _copyCoefficients(
    Float32List coefficients,
    int levelWidth,
    int levelHeight,
    Map<String, dynamic> subband,
    double delta,
    int mb,
    bool reversible,
    bool segmentationSymbolUsed,
  ) {
    final x0 = _i(subband['tbx0']);
    final y0 = _i(subband['tby0']);
    final width = _i(subband['tbx1']) - _i(subband['tbx0']);
    final codeblocks = _l(subband['codeblocks']);
    final type = subband['type'] as String;
    final right = type[0] == 'H' ? 1 : 0;
    final bottom = type[1] == 'H' ? levelWidth : 0;
    for (final raw in codeblocks) {
      final codeblock = _m(raw);
      final blockWidth = _i(codeblock['tbx1_']) - _i(codeblock['tbx0_']);
      final blockHeight = _i(codeblock['tby1_']) - _i(codeblock['tby0_']);
      if (blockWidth == 0 || blockHeight == 0 || codeblock['data'] == null) {
        continue;
      }

      final bitModel = _BitModel(
        blockWidth,
        blockHeight,
        codeblock['subbandType'] as String,
        _i(codeblock['zeroBitPlanes']),
        mb,
      );
      var currentCodingpassType = 2;
      final chunks = _l(codeblock['data']);
      var totalLength = 0;
      var codingpasses = 0;
      for (final chunkRaw in chunks) {
        final chunk = _m(chunkRaw);
        totalLength += _i(chunk['end']) - _i(chunk['start']);
        codingpasses += _i(chunk['codingpasses']);
      }
      final encodedData = Uint8List(totalLength);
      var writePosition = 0;
      for (final chunkRaw in chunks) {
        final chunk = _m(chunkRaw);
        final source = chunk['data'] as Uint8List;
        final start = _i(chunk['start']);
        final end = _i(chunk['end']);
        encodedData.setRange(
          writePosition,
          writePosition + end - start,
          source,
          start,
        );
        writePosition += end - start;
      }
      final decoder = ArithmeticDecoder(encodedData, 0, totalLength);
      bitModel.setDecoder(decoder);
      for (var j = 0; j < codingpasses; j++) {
        switch (currentCodingpassType) {
          case 0:
            bitModel.runSignificancePropagationPass();
            break;
          case 1:
            bitModel.runMagnitudeRefinementPass();
            break;
          case 2:
            bitModel.runCleanupPass();
            if (segmentationSymbolUsed) bitModel.checkSegmentationSymbol();
            break;
        }
        currentCodingpassType = (currentCodingpassType + 1) % 3;
      }

      var offset =
          _i(codeblock['tbx0_']) - x0 + (_i(codeblock['tby0_']) - y0) * width;
      final sign = bitModel.coefficentsSign;
      final magnitude = bitModel.coefficentsMagnitude;
      final bitsDecoded = bitModel.bitsDecoded;
      final magnitudeCorrection = reversible ? 0.0 : 0.5;
      var posInBlock = 0;
      final interleave = type != 'LL';
      for (var j = 0; j < blockHeight; j++) {
        final row = (offset / width).truncate();
        final levelOffset = 2 * row * (levelWidth - width) + right + bottom;
        for (var k = 0; k < blockWidth; k++) {
          var n = magnitude[posInBlock].toDouble();
          if (n != 0) {
            n = (n + magnitudeCorrection) * delta;
            if (sign[posInBlock] != 0) n = -n;
            final nb = bitsDecoded[posInBlock];
            final target = interleave ? levelOffset + (offset << 1) : offset;
            if (target >= 0 && target < coefficients.length) {
              if (reversible && nb >= mb) {
                coefficients[target] = n;
              } else {
                final exponent = mb - nb;
                coefficients[target] = n * math.pow(2, exponent).toDouble();
              }
            }
          }
          offset++;
          posInBlock++;
        }
        offset += width - blockWidth;
      }
    }
  }

  Map<String, dynamic> _transformTile(
    Map<String, dynamic> context,
    Map<String, dynamic> tile,
    int c,
  ) {
    final component = _m(_l(tile['components'])[c]);
    final codingStyleParameters = _m(component['codingStyleParameters']);
    final quantizationParameters = _m(component['quantizationParameters']);
    final decompositionLevelsCount = _i(
      codingStyleParameters['decompositionLevelsCount'],
    );
    final spqcds = _l(quantizationParameters['SPqcds']);
    final scalarExpounded = _b(quantizationParameters['scalarExpounded']);
    final guardBits = _i(quantizationParameters['guardBits']);
    final segmentationSymbolUsed = _b(
      codingStyleParameters['segmentationSymbolUsed'],
    );
    final precision = _i(_m(_l(context['components'])[c])['precision']);
    final reversible =
        _i(codingStyleParameters['reversibleTransformation']) != 0;
    final transform =
        reversible ? _ReversibleTransform() : _IrreversibleTransform();

    final subbandCoefficients = <Map<String, dynamic>>[];
    var b = 0;
    for (var i = 0; i <= decompositionLevelsCount; i++) {
      final resolution = _m(_l(component['resolutions'])[i]);
      final levelWidth = _i(resolution['trx1']) - _i(resolution['trx0']);
      final levelHeight = _i(resolution['try1']) - _i(resolution['try0']);
      final coefficients = Float32List(levelWidth * levelHeight);
      for (final rawSubband in _l(resolution['subbands'])) {
        final subband = _m(rawSubband);
        late int mu;
        late int epsilon;
        if (!scalarExpounded) {
          final q = _m(spqcds[0]);
          mu = _i(q['mu']);
          epsilon = _i(q['epsilon']) + (i > 0 ? 1 - i : 0);
        } else {
          final q = _m(spqcds[b++]);
          mu = _i(q['mu']);
          epsilon = _i(q['epsilon']);
        }
        final gainLog2 = _subbandsGainLog2[subband['type']]!;
        final delta = reversible
            ? 1.0
            : math.pow(2, precision + gainLog2 - epsilon).toDouble() *
                (1 + mu / 2048);
        final mb = guardBits + epsilon - 1;
        _copyCoefficients(
          coefficients,
          levelWidth,
          levelHeight,
          subband,
          delta,
          mb,
          reversible,
          segmentationSymbolUsed,
        );
      }
      subbandCoefficients.add(<String, dynamic>{
        'width': levelWidth,
        'height': levelHeight,
        'items': coefficients,
      });
    }
    final result = transform.calculate(
      subbandCoefficients,
      _i(component['tcx0']),
      _i(component['tcy0']),
    );
    return <String, dynamic>{
      'left': component['tcx0'],
      'top': component['tcy0'],
      'width': result['width'],
      'height': result['height'],
      'items': result['items'],
    };
  }

  List<JpxTile> _transformComponents(Map<String, dynamic> context) {
    final siz = _m(context['SIZ']);
    final components = _l(context['components']);
    final componentsCount = _i(siz['Csiz']);
    final resultImages = <JpxTile>[];

    for (final rawTile in _l(context['tiles'])) {
      final tile = _m(rawTile);
      final transformedTiles = <Map<String, dynamic>>[];

      for (var c = 0; c < componentsCount; c++) {
        transformedTiles.add(_transformTile(context, tile, c));
      }

      final tile0 = transformedTiles[0];
      final y0base = tile0['items'] as Float32List;

      // Sempre RGBA.
      final out = Uint8List(y0base.length * 4);

      if (_i(
            _m(
              tile['codingStyleDefaultParameters'],
            )['multipleComponentTransform'],
          ) !=
          0) {
        final y0items = transformedTiles[0]['items'] as Float32List;
        final y1items = transformedTiles[1]['items'] as Float32List;
        final y2items = transformedTiles[2]['items'] as Float32List;

        final Float32List? y3items = componentsCount >= 4
            ? transformedTiles[3]['items'] as Float32List
            : null;

        final shift = _i(_m(components[0])['precision']) - 8;
        final offset = _scaled128(shift) + 0.5;

        final component0 = _m(_l(tile['components'])[0]);

        final count = y0items.length;

        if (_i(
              _m(
                component0['codingStyleParameters'],
              )['reversibleTransformation'],
            ) ==
            0) {
          // Irreversible ICT: YCbCr -> RGB
          for (var j = 0, p = 0; j < count; j++, p += 4) {
            final y0 = y0items[j] + offset;
            final y1 = y1items[j];
            final y2 = y2items[j];

            out[p] = _clamp8(_rightShiftNum(y0 + 1.402 * y2, shift));

            out[p + 1] = _clamp8(
              _rightShiftNum(y0 - 0.34413 * y1 - 0.71414 * y2, shift),
            );

            out[p + 2] = _clamp8(_rightShiftNum(y0 + 1.772 * y1, shift));

            // Alpha.
            out[p + 3] = y3items != null
                ? _clamp8(_rightShiftNum(y3items[j] + offset, shift))
                : 255;
          }
        } else {
          // Reversible RCT.
          for (var j = 0, p = 0; j < count; j++, p += 4) {
            final y0 = y0items[j] + offset;
            final y1 = y1items[j];
            final y2 = y2items[j];

            final g = y0 - ((y2 + y1).truncate() >> 2);

            out[p] = _clamp8(_rightShiftNum(g + y2, shift));

            out[p + 1] = _clamp8(_rightShiftNum(g, shift));

            out[p + 2] = _clamp8(_rightShiftNum(g + y1, shift));

            // Alpha.
            out[p + 3] = y3items != null
                ? _clamp8(_rightShiftNum(y3items[j] + offset, shift))
                : 255;
          }
        }
      } else {
        // Nessuna multiple component transform.
        //
        // Portiamo comunque tutto nel formato RGBA.
        final count = y0base.length;

        final items0 = transformedTiles[0]['items'] as Float32List;

        final Float32List? items1 = componentsCount >= 2
            ? transformedTiles[1]['items'] as Float32List
            : null;

        final Float32List? items2 = componentsCount >= 3
            ? transformedTiles[2]['items'] as Float32List
            : null;

        final Float32List? items3 = componentsCount >= 4
            ? transformedTiles[3]['items'] as Float32List
            : null;

        final shift0 = _i(_m(components[0])['precision']) - 8;
        final offset0 = _scaled128(shift0) + 0.5;

        final shift1 =
            componentsCount >= 2 ? _i(_m(components[1])['precision']) - 8 : 0;

        final offset1 = componentsCount >= 2 ? _scaled128(shift1) + 0.5 : 0.0;

        final shift2 =
            componentsCount >= 3 ? _i(_m(components[2])['precision']) - 8 : 0;

        final offset2 = componentsCount >= 3 ? _scaled128(shift2) + 0.5 : 0.0;

        final shift3 =
            componentsCount >= 4 ? _i(_m(components[3])['precision']) - 8 : 0;

        final offset3 = componentsCount >= 4 ? _scaled128(shift3) + 0.5 : 0.0;

        for (var j = 0, p = 0; j < count; j++, p += 4) {
          out[p] = _clamp8(_rightShiftNum(items0[j] + offset0, shift0));

          out[p + 1] = items1 != null
              ? _clamp8(_rightShiftNum(items1[j] + offset1, shift1))
              : out[p];

          out[p + 2] = items2 != null
              ? _clamp8(_rightShiftNum(items2[j] + offset2, shift2))
              : out[p];

          out[p + 3] = items3 != null
              ? _clamp8(_rightShiftNum(items3[j] + offset3, shift3))
              : 255;
        }
      }

      resultImages.add(
        JpxTile(
          left: _i(tile0['left']),
          top: _i(tile0['top']),
          width: _i(tile0['width']),
          height: _i(tile0['height']),
          items: out,
        ),
      );
    }

    return resultImages;
  }

  void _initializeTile(Map<String, dynamic> context, int tileIndex) {
    final siz = _m(context['SIZ']);
    final componentsCount = _i(siz['Csiz']);
    final tile = _m(_l(context['tiles'])[tileIndex]);
    final currentTile = _m(context['currentTile']);
    for (var c = 0; c < componentsCount; c++) {
      final component = _m(_l(tile['components'])[c]);
      final qcc = _l(currentTile['QCC']);
      final qcdOrQcc =
          c < qcc.length && qcc[c] != null ? qcc[c] : currentTile['QCD'];
      component['quantizationParameters'] = qcdOrQcc;
      final coc = _l(currentTile['COC']);
      final codOrCoc =
          c < coc.length && coc[c] != null ? coc[c] : currentTile['COD'];
      component['codingStyleParameters'] = codOrCoc;
    }
    tile['codingStyleDefaultParameters'] = currentTile['COD'];
  }
}

num _scaled128(int shift) =>
    shift >= 0 ? 128 * (1 << shift) : 128 / math.pow(2, -shift);

int _rightShiftNum(num value, int shift) {
  if (shift >= 0) return value.truncate() >> shift;
  return (value * math.pow(2, -shift)).truncate();
}

Map<String, dynamic> _createPacket(
  Map<String, dynamic> resolution,
  int precinctNumber,
  int layerNumber,
) {
  final precinctCodeblocks = <dynamic>[];
  for (final rawSubband in _l(resolution['subbands'])) {
    final subband = _m(rawSubband);
    for (final rawCodeblock in _l(subband['codeblocks'])) {
      final codeblock = _m(rawCodeblock);
      if (_i(codeblock['precinctNumber']) == precinctNumber) {
        precinctCodeblocks.add(codeblock);
      }
    }
  }
  return <String, dynamic>{
    'layerNumber': layerNumber,
    'codeblocks': precinctCodeblocks,
  };
}

abstract class _PacketIterator {
  Map<String, dynamic> nextPacket();
}

class _LrcpIterator implements _PacketIterator {
  _LrcpIterator(Map<String, dynamic> context)
      : tile =
            _m(_l(context['tiles'])[_i(_m(context['currentTile'])['index'])]),
        componentsCount = _i(_m(context['SIZ'])['Csiz']) {
    layersCount = _i(_m(tile['codingStyleDefaultParameters'])['layersCount']);
    for (var q = 0; q < componentsCount; q++) {
      maxDecompositionLevelsCount = math.max(
        maxDecompositionLevelsCount,
        _i(
          _m(
            _m(_l(tile['components'])[q])['codingStyleParameters'],
          )['decompositionLevelsCount'],
        ),
      );
    }
  }

  final Map<String, dynamic> tile;
  final int componentsCount;
  late final int layersCount;
  int maxDecompositionLevelsCount = 0;
  int l = 0, r = 0, i = 0, k = 0;

  @override
  Map<String, dynamic> nextPacket() {
    for (; l < layersCount; l++) {
      for (; r <= maxDecompositionLevelsCount; r++) {
        for (; i < componentsCount; i++) {
          final component = _m(_l(tile['components'])[i]);
          if (r >
              _i(
                _m(
                  component['codingStyleParameters'],
                )['decompositionLevelsCount'],
              )) {
            continue;
          }
          final resolution = _m(_l(component['resolutions'])[r]);
          final numprecincts = _i(
            _m(resolution['precinctParameters'])['numprecincts'],
          );
          if (k < numprecincts) {
            return _createPacket(resolution, k++, l);
          }
          k = 0;
        }
        i = 0;
      }
      r = 0;
    }
    throw JpxError('Out of packets');
  }
}

class _RlcpIterator implements _PacketIterator {
  _RlcpIterator(Map<String, dynamic> context)
      : tile =
            _m(_l(context['tiles'])[_i(_m(context['currentTile'])['index'])]),
        componentsCount = _i(_m(context['SIZ'])['Csiz']) {
    layersCount = _i(_m(tile['codingStyleDefaultParameters'])['layersCount']);
    for (var q = 0; q < componentsCount; q++) {
      maxDecompositionLevelsCount = math.max(
        maxDecompositionLevelsCount,
        _i(
          _m(
            _m(_l(tile['components'])[q])['codingStyleParameters'],
          )['decompositionLevelsCount'],
        ),
      );
    }
  }

  final Map<String, dynamic> tile;
  final int componentsCount;
  late final int layersCount;
  int maxDecompositionLevelsCount = 0;
  int r = 0, l = 0, i = 0, k = 0;

  @override
  Map<String, dynamic> nextPacket() {
    for (; r <= maxDecompositionLevelsCount; r++) {
      for (; l < layersCount; l++) {
        for (; i < componentsCount; i++) {
          final component = _m(_l(tile['components'])[i]);
          if (r >
              _i(
                _m(
                  component['codingStyleParameters'],
                )['decompositionLevelsCount'],
              )) {
            continue;
          }
          final resolution = _m(_l(component['resolutions'])[r]);
          final numprecincts = _i(
            _m(resolution['precinctParameters'])['numprecincts'],
          );
          if (k < numprecincts) {
            return _createPacket(resolution, k++, l);
          }
          k = 0;
        }
        i = 0;
      }
      l = 0;
    }
    throw JpxError('Out of packets');
  }
}

class _RpclIterator implements _PacketIterator {
  _RpclIterator(Map<String, dynamic> context)
      : tile =
            _m(_l(context['tiles'])[_i(_m(context['currentTile'])['index'])]),
        componentsCount = _i(_m(context['SIZ'])['Csiz']) {
    layersCount = _i(_m(tile['codingStyleDefaultParameters'])['layersCount']);
    for (var c = 0; c < componentsCount; c++) {
      maxDecompositionLevelsCount = math.max(
        maxDecompositionLevelsCount,
        _i(
          _m(
            _m(_l(tile['components'])[c])['codingStyleParameters'],
          )['decompositionLevelsCount'],
        ),
      );
    }
    maxNumPrecinctsInLevel = Int32List(maxDecompositionLevelsCount + 1);
    for (var level = 0; level <= maxDecompositionLevelsCount; level++) {
      var maxNumPrecincts = 0;
      for (var c = 0; c < componentsCount; c++) {
        final resolutions = _l(_m(_l(tile['components'])[c])['resolutions']);
        if (level < resolutions.length) {
          maxNumPrecincts = math.max(
            maxNumPrecincts,
            _i(
              _m(_m(resolutions[level])['precinctParameters'])['numprecincts'],
            ),
          );
        }
      }
      maxNumPrecinctsInLevel[level] = maxNumPrecincts;
    }
  }

  final Map<String, dynamic> tile;
  final int componentsCount;
  late final int layersCount;
  int maxDecompositionLevelsCount = 0;
  late final Int32List maxNumPrecinctsInLevel;
  int l = 0, r = 0, c = 0, p = 0;

  @override
  Map<String, dynamic> nextPacket() {
    for (; r <= maxDecompositionLevelsCount; r++) {
      for (; p < maxNumPrecinctsInLevel[r]; p++) {
        for (; c < componentsCount; c++) {
          final component = _m(_l(tile['components'])[c]);
          if (r >
              _i(
                _m(
                  component['codingStyleParameters'],
                )['decompositionLevelsCount'],
              )) {
            continue;
          }
          final resolution = _m(_l(component['resolutions'])[r]);
          final numprecincts = _i(
            _m(resolution['precinctParameters'])['numprecincts'],
          );
          if (p >= numprecincts) continue;
          if (l < layersCount) return _createPacket(resolution, p, l++);
          l = 0;
        }
        c = 0;
      }
      p = 0;
    }
    throw JpxError('Out of packets');
  }
}

int? _getPrecinctIndexIfExist(
  int pxIndex,
  int pyIndex,
  Map<String, dynamic> sizeInImageScale,
  Map<String, dynamic> precinctIterationSizes,
  Map<String, dynamic> resolution,
) {
  final posX = pxIndex * _i(precinctIterationSizes['minWidth']);
  final posY = pyIndex * _i(precinctIterationSizes['minHeight']);
  if (posX % _i(sizeInImageScale['width']) != 0 ||
      posY % _i(sizeInImageScale['height']) != 0) {
    return null;
  }
  // Intentionally matches the JavaScript source exactly.
  final startPrecinctRowIndex = (posY / _i(sizeInImageScale['width'])) *
      _i(_m(resolution['precinctParameters'])['numprecinctswide']);
  return (posX / _i(sizeInImageScale['height']) + startPrecinctRowIndex)
      .truncate();
}

Map<String, dynamic> _getPrecinctSizesInImageScale(Map<String, dynamic> tile) {
  final components = _l(tile['components']);
  final componentsCount = components.length;
  var minWidth = 1 << 62;
  var minHeight = 1 << 62;
  var maxNumWide = 0;
  var maxNumHigh = 0;
  final sizePerComponent = List<dynamic>.filled(componentsCount, null);
  for (var c = 0; c < componentsCount; c++) {
    final component = _m(components[c]);
    final decompositionLevelsCount = _i(
      _m(component['codingStyleParameters'])['decompositionLevelsCount'],
    );
    final sizePerResolution = List<dynamic>.filled(
      decompositionLevelsCount + 1,
      null,
    );
    var minWidthCurrentComponent = 1 << 62;
    var minHeightCurrentComponent = 1 << 62;
    var maxNumWideCurrentComponent = 0;
    var maxNumHighCurrentComponent = 0;
    var scale = 1;
    for (var r = decompositionLevelsCount; r >= 0; r--) {
      final resolution = _m(_l(component['resolutions'])[r]);
      final pp = _m(resolution['precinctParameters']);
      final widthCurrentResolution = scale * _i(pp['precinctWidth']);
      final heightCurrentResolution = scale * _i(pp['precinctHeight']);
      minWidthCurrentComponent = math.min(
        minWidthCurrentComponent,
        widthCurrentResolution,
      );
      minHeightCurrentComponent = math.min(
        minHeightCurrentComponent,
        heightCurrentResolution,
      );
      maxNumWideCurrentComponent = math.max(
        maxNumWideCurrentComponent,
        _i(pp['numprecinctswide']),
      );
      maxNumHighCurrentComponent = math.max(
        maxNumHighCurrentComponent,
        _i(pp['numprecinctshigh']),
      );
      sizePerResolution[r] = <String, dynamic>{
        'width': widthCurrentResolution,
        'height': heightCurrentResolution,
      };
      scale <<= 1;
    }
    minWidth = math.min(minWidth, minWidthCurrentComponent);
    minHeight = math.min(minHeight, minHeightCurrentComponent);
    maxNumWide = math.max(maxNumWide, maxNumWideCurrentComponent);
    maxNumHigh = math.max(maxNumHigh, maxNumHighCurrentComponent);
    sizePerComponent[c] = <String, dynamic>{
      'resolutions': sizePerResolution,
      'minWidth': minWidthCurrentComponent,
      'minHeight': minHeightCurrentComponent,
      'maxNumWide': maxNumWideCurrentComponent,
      'maxNumHigh': maxNumHighCurrentComponent,
    };
  }
  return <String, dynamic>{
    'components': sizePerComponent,
    'minWidth': minWidth,
    'minHeight': minHeight,
    'maxNumWide': maxNumWide,
    'maxNumHigh': maxNumHigh,
  };
}

class _PcrlIterator implements _PacketIterator {
  _PcrlIterator(Map<String, dynamic> context)
      : tile =
            _m(_l(context['tiles'])[_i(_m(context['currentTile'])['index'])]),
        componentsCount = _i(_m(context['SIZ'])['Csiz']) {
    layersCount = _i(_m(tile['codingStyleDefaultParameters'])['layersCount']);
    precinctsSizes = _getPrecinctSizesInImageScale(tile);
  }

  final Map<String, dynamic> tile;
  final int componentsCount;
  late final int layersCount;
  late final Map<String, dynamic> precinctsSizes;
  int l = 0, r = 0, c = 0, px = 0, py = 0;

  @override
  Map<String, dynamic> nextPacket() {
    final iteration = precinctsSizes;
    for (; py < _i(iteration['maxNumHigh']); py++) {
      for (; px < _i(iteration['maxNumWide']); px++) {
        for (; c < componentsCount; c++) {
          final component = _m(_l(tile['components'])[c]);
          final decompositionLevelsCount = _i(
            _m(component['codingStyleParameters'])['decompositionLevelsCount'],
          );
          for (; r <= decompositionLevelsCount; r++) {
            final resolution = _m(_l(component['resolutions'])[r]);
            final componentSizes = _m(_l(precinctsSizes['components'])[c]);
            final sizeInImageScale = _m(_l(componentSizes['resolutions'])[r]);
            final k = _getPrecinctIndexIfExist(
              px,
              py,
              sizeInImageScale,
              iteration,
              resolution,
            );
            if (k == null) continue;
            if (l < layersCount) return _createPacket(resolution, k, l++);
            l = 0;
          }
          r = 0;
        }
        c = 0;
      }
      px = 0;
    }
    throw JpxError('Out of packets');
  }
}

class _CprlIterator implements _PacketIterator {
  _CprlIterator(Map<String, dynamic> context)
      : tile =
            _m(_l(context['tiles'])[_i(_m(context['currentTile'])['index'])]),
        componentsCount = _i(_m(context['SIZ'])['Csiz']) {
    layersCount = _i(_m(tile['codingStyleDefaultParameters'])['layersCount']);
    precinctsSizes = _getPrecinctSizesInImageScale(tile);
  }

  final Map<String, dynamic> tile;
  final int componentsCount;
  late final int layersCount;
  late final Map<String, dynamic> precinctsSizes;
  int l = 0, r = 0, c = 0, px = 0, py = 0;

  @override
  Map<String, dynamic> nextPacket() {
    for (; c < componentsCount; c++) {
      final component = _m(_l(tile['components'])[c]);
      final iteration = _m(_l(precinctsSizes['components'])[c]);
      final decompositionLevelsCount = _i(
        _m(component['codingStyleParameters'])['decompositionLevelsCount'],
      );
      for (; py < _i(iteration['maxNumHigh']); py++) {
        for (; px < _i(iteration['maxNumWide']); px++) {
          for (; r <= decompositionLevelsCount; r++) {
            final resolution = _m(_l(component['resolutions'])[r]);
            final sizeInImageScale = _m(_l(iteration['resolutions'])[r]);
            final k = _getPrecinctIndexIfExist(
              px,
              py,
              sizeInImageScale,
              iteration,
              resolution,
            );
            if (k == null) continue;
            if (l < layersCount) return _createPacket(resolution, k, l++);
            l = 0;
          }
          r = 0;
        }
        px = 0;
      }
      py = 0;
    }
    throw JpxError('Out of packets');
  }
}

class _TagTree {
  _TagTree(int width, int height) {
    final levelsLength = log2Ceil(math.max(width, height)) + 1;
    for (var i = 0; i < levelsLength; i++) {
      levels.add(_TreeLevel(width, height, sparse: true));
      width = (width / 2).ceil();
      height = (height / 2).ceil();
    }
  }

  final List<_TreeLevel> levels = <_TreeLevel>[];
  int currentLevel = 0;
  int? value;

  void reset(int i, int j) {
    var localCurrentLevel = 0;
    var localValue = 0;
    late _TreeLevel level;
    while (localCurrentLevel < levels.length) {
      level = levels[localCurrentLevel];
      final index = i + j * level.width;
      final item = level.itemAt(index);
      if (item != null) {
        localValue = item;
        break;
      }
      level.index = index;
      i >>= 1;
      j >>= 1;
      localCurrentLevel++;
    }
    localCurrentLevel--;
    level = levels[localCurrentLevel];
    level.setItem(level.index, localValue);
    currentLevel = localCurrentLevel;
    value = null;
  }

  void incrementValue() {
    final level = levels[currentLevel];
    level.setItem(level.index, (level.itemAt(level.index) ?? 0) + 1);
  }

  bool nextLevel() {
    var localCurrentLevel = currentLevel;
    var level = levels[localCurrentLevel];
    final localValue = level.itemAt(level.index)!;
    localCurrentLevel--;
    if (localCurrentLevel < 0) {
      value = localValue;
      return false;
    }
    currentLevel = localCurrentLevel;
    level = levels[localCurrentLevel];
    level.setItem(level.index, localValue);
    return true;
  }
}

class _TreeLevel {
  _TreeLevel(this.width, this.height, {required bool sparse})
      : sparseItems = sparse ? <int, int>{} : null,
        denseItems = sparse ? null : Uint8List(width * height);

  final int width;
  final int height;
  final Map<int, int>? sparseItems;
  final Uint8List? denseItems;
  int index = 0;

  int? itemAt(int index) =>
      sparseItems != null ? sparseItems![index] : denseItems![index];
  void setItem(int index, int value) {
    if (sparseItems != null) {
      sparseItems![index] = value;
    } else {
      denseItems![index] = value;
    }
  }
}

class _InclusionTree {
  _InclusionTree(int width, int height, int defaultValue) {
    final levelsLength = log2Ceil(math.max(width, height)) + 1;
    for (var i = 0; i < levelsLength; i++) {
      final level = _TreeLevel(width, height, sparse: false);
      level.denseItems!.fillRange(
        0,
        level.denseItems!.length,
        defaultValue & 0xff,
      );
      levels.add(level);
      width = (width / 2).ceil();
      height = (height / 2).ceil();
    }
  }

  final List<_TreeLevel> levels = <_TreeLevel>[];
  int currentLevel = 0;

  bool reset(int i, int j, int stopValue) {
    var localCurrentLevel = 0;
    while (localCurrentLevel < levels.length) {
      final level = levels[localCurrentLevel];
      final index = i + j * level.width;
      level.index = index;
      final value = level.denseItems![index];
      if (value == 0xff) break;
      if (value > stopValue) {
        currentLevel = localCurrentLevel;
        propagateValues();
        return false;
      }
      i >>= 1;
      j >>= 1;
      localCurrentLevel++;
    }
    currentLevel = localCurrentLevel - 1;
    return true;
  }

  void incrementValue(int stopValue) {
    final level = levels[currentLevel];
    level.denseItems![level.index] = (stopValue + 1) & 0xff;
    propagateValues();
  }

  void propagateValues() {
    var levelIndex = currentLevel;
    var level = levels[levelIndex];
    final currentValue = level.denseItems![level.index];
    while (--levelIndex >= 0) {
      level = levels[levelIndex];
      level.denseItems![level.index] = currentValue;
    }
  }

  bool nextLevel() {
    var localCurrentLevel = currentLevel;
    var level = levels[localCurrentLevel];
    final value = level.denseItems![level.index];
    level.denseItems![level.index] = 0xff;
    localCurrentLevel--;
    if (localCurrentLevel < 0) return false;
    currentLevel = localCurrentLevel;
    level = levels[localCurrentLevel];
    level.denseItems![level.index] = value;
    return true;
  }
}

class _BitModel {
  _BitModel(this.width, this.height, String subband, int zeroBitPlanes, int mb)
      : contextLabelTable = subband == 'HH'
            ? _hhContextLabel
            : subband == 'HL'
                ? _hlContextLabel
                : _llAndLhContextLabel,
        neighborsSignificance = Uint8List(width * height),
        coefficentsSign = Uint8List(width * height),
        coefficentsMagnitude = mb > 14
            ? Uint32List(width * height)
            : mb > 6
                ? Uint16List(width * height)
                : Uint8List(width * height),
        processingFlags = Uint8List(width * height),
        bitsDecoded = Uint8List(width * height) {
    if (zeroBitPlanes != 0) {
      bitsDecoded.fillRange(0, bitsDecoded.length, zeroBitPlanes);
    }
    reset();
  }

  static const int uniformContext = 17;
  static const int runlengthContext = 18;

  static final Uint8List _llAndLhContextLabel = Uint8List.fromList(<int>[
    0,
    5,
    8,
    0,
    3,
    7,
    8,
    0,
    4,
    7,
    8,
    0,
    0,
    0,
    0,
    0,
    1,
    6,
    8,
    0,
    3,
    7,
    8,
    0,
    4,
    7,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    6,
    8,
    0,
    3,
    7,
    8,
    0,
    4,
    7,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    6,
    8,
    0,
    3,
    7,
    8,
    0,
    4,
    7,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    6,
    8,
    0,
    3,
    7,
    8,
    0,
    4,
    7,
    8,
  ]);
  static final Uint8List _hlContextLabel = Uint8List.fromList(<int>[
    0,
    3,
    4,
    0,
    5,
    7,
    7,
    0,
    8,
    8,
    8,
    0,
    0,
    0,
    0,
    0,
    1,
    3,
    4,
    0,
    6,
    7,
    7,
    0,
    8,
    8,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    3,
    4,
    0,
    6,
    7,
    7,
    0,
    8,
    8,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    3,
    4,
    0,
    6,
    7,
    7,
    0,
    8,
    8,
    8,
    0,
    0,
    0,
    0,
    0,
    2,
    3,
    4,
    0,
    6,
    7,
    7,
    0,
    8,
    8,
    8,
  ]);
  static final Uint8List _hhContextLabel = Uint8List.fromList(<int>[
    0,
    1,
    2,
    0,
    1,
    2,
    2,
    0,
    2,
    2,
    2,
    0,
    0,
    0,
    0,
    0,
    3,
    4,
    5,
    0,
    4,
    5,
    5,
    0,
    5,
    5,
    5,
    0,
    0,
    0,
    0,
    0,
    6,
    7,
    7,
    0,
    7,
    7,
    7,
    0,
    7,
    7,
    7,
    0,
    0,
    0,
    0,
    0,
    8,
    8,
    8,
    0,
    8,
    8,
    8,
    0,
    8,
    8,
    8,
    0,
    0,
    0,
    0,
    0,
    8,
    8,
    8,
    0,
    8,
    8,
    8,
    0,
    8,
    8,
    8,
  ]);

  final int width;
  final int height;
  final Uint8List contextLabelTable;
  final Uint8List neighborsSignificance;
  final Uint8List coefficentsSign;
  final List<int> coefficentsMagnitude;
  final Uint8List processingFlags;
  final Uint8List bitsDecoded;
  late Int8List contexts;
  late ArithmeticDecoder decoder;

  void setDecoder(ArithmeticDecoder value) => decoder = value;

  void reset() {
    contexts = Int8List(19);
    contexts[0] = 4 << 1;
    contexts[uniformContext] = 46 << 1;
    contexts[runlengthContext] = 3 << 1;
  }

  void setNeighborsSignificance(int row, int column, int index) {
    final left = column > 0;
    final right = column + 1 < width;
    if (row > 0) {
      final i = index - width;
      if (left) neighborsSignificance[i - 1] += 0x10;
      if (right) neighborsSignificance[i + 1] += 0x10;
      neighborsSignificance[i] += 0x04;
    }
    if (row + 1 < height) {
      final i = index + width;
      if (left) neighborsSignificance[i - 1] += 0x10;
      if (right) neighborsSignificance[i + 1] += 0x10;
      neighborsSignificance[i] += 0x04;
    }
    if (left) neighborsSignificance[index - 1] += 0x01;
    if (right) neighborsSignificance[index + 1] += 0x01;
    neighborsSignificance[index] |= 0x80;
  }

  void runSignificancePropagationPass() {
    const processedInverseMask = ~1;
    const processedMask = 1;
    const firstMagnitudeBitMask = 2;
    for (var i0 = 0; i0 < height; i0 += 4) {
      for (var j = 0; j < width; j++) {
        var index = i0 * width + j;
        for (var i1 = 0; i1 < 4; i1++, index += width) {
          final i = i0 + i1;
          if (i >= height) break;
          processingFlags[index] &= processedInverseMask;
          if (coefficentsMagnitude[index] != 0 ||
              neighborsSignificance[index] == 0) {
            continue;
          }
          final contextLabel = contextLabelTable[neighborsSignificance[index]];
          final decision = decoder.readBit(contexts, contextLabel);
          if (decision != 0) {
            final sign = decodeSignBit(i, j, index);
            coefficentsSign[index] = sign;
            coefficentsMagnitude[index] = 1;
            setNeighborsSignificance(i, j, index);
            processingFlags[index] |= firstMagnitudeBitMask;
          }
          bitsDecoded[index]++;
          processingFlags[index] |= processedMask;
        }
      }
    }
  }

  int decodeSignBit(int row, int column, int index) {
    late int contribution;
    int sign0, sign1;
    var significance1 = column > 0 && coefficentsMagnitude[index - 1] != 0;
    if (column + 1 < width && coefficentsMagnitude[index + 1] != 0) {
      sign1 = coefficentsSign[index + 1];
      if (significance1) {
        sign0 = coefficentsSign[index - 1];
        contribution = 1 - sign1 - sign0;
      } else {
        contribution = 1 - sign1 - sign1;
      }
    } else if (significance1) {
      sign0 = coefficentsSign[index - 1];
      contribution = 1 - sign0 - sign0;
    } else {
      contribution = 0;
    }
    final horizontalContribution = 3 * contribution;
    significance1 = row > 0 && coefficentsMagnitude[index - width] != 0;
    if (row + 1 < height && coefficentsMagnitude[index + width] != 0) {
      sign1 = coefficentsSign[index + width];
      if (significance1) {
        sign0 = coefficentsSign[index - width];
        contribution = 1 - sign1 - sign0 + horizontalContribution;
      } else {
        contribution = 1 - sign1 - sign1 + horizontalContribution;
      }
    } else if (significance1) {
      sign0 = coefficentsSign[index - width];
      contribution = 1 - sign0 - sign0 + horizontalContribution;
    } else {
      contribution = horizontalContribution;
    }
    if (contribution >= 0) {
      return decoder.readBit(contexts, 9 + contribution);
    }
    return decoder.readBit(contexts, 9 - contribution) ^ 1;
  }

  void runMagnitudeRefinementPass() {
    const processedMask = 1;
    const firstMagnitudeBitMask = 2;
    final length = width * height;
    final width4 = width * 4;
    for (var index0 = 0; index0 < length;) {
      final indexNext = math.min(length, index0 + width4);
      for (var j = 0; j < width; j++) {
        for (var index = index0 + j; index < indexNext; index += width) {
          if (coefficentsMagnitude[index] == 0 ||
              (processingFlags[index] & processedMask) != 0) {
            continue;
          }
          var contextLabel = 16;
          if ((processingFlags[index] & firstMagnitudeBitMask) != 0) {
            processingFlags[index] ^= firstMagnitudeBitMask;
            final significance = neighborsSignificance[index] & 127;
            contextLabel = significance == 0 ? 15 : 14;
          }
          final bit = decoder.readBit(contexts, contextLabel);
          coefficentsMagnitude[index] =
              (coefficentsMagnitude[index] << 1) | bit;
          bitsDecoded[index]++;
          processingFlags[index] |= processedMask;
        }
      }
      index0 = indexNext;
    }
  }

  void runCleanupPass() {
    const processedMask = 1;
    const firstMagnitudeBitMask = 2;
    final oneRowDown = width;
    final twoRowsDown = width * 2;
    final threeRowsDown = width * 3;
    for (var i0 = 0; i0 < height;) {
      final iNext = math.min(i0 + 4, height);
      final indexBase = i0 * width;
      final checkAllEmpty = i0 + 3 < height;
      for (var j = 0; j < width; j++) {
        final index0 = indexBase + j;
        final allEmpty = checkAllEmpty &&
            processingFlags[index0] == 0 &&
            processingFlags[index0 + oneRowDown] == 0 &&
            processingFlags[index0 + twoRowsDown] == 0 &&
            processingFlags[index0 + threeRowsDown] == 0 &&
            neighborsSignificance[index0] == 0 &&
            neighborsSignificance[index0 + oneRowDown] == 0 &&
            neighborsSignificance[index0 + twoRowsDown] == 0 &&
            neighborsSignificance[index0 + threeRowsDown] == 0;
        var i1 = 0;
        var index = index0;
        var i = i0;
        var sign = 0;
        if (allEmpty) {
          final hasSignificantCoefficient = decoder.readBit(
            contexts,
            runlengthContext,
          );
          if (hasSignificantCoefficient == 0) {
            bitsDecoded[index0]++;
            bitsDecoded[index0 + oneRowDown]++;
            bitsDecoded[index0 + twoRowsDown]++;
            bitsDecoded[index0 + threeRowsDown]++;
            continue;
          }
          i1 = (decoder.readBit(contexts, uniformContext) << 1) |
              decoder.readBit(contexts, uniformContext);
          if (i1 != 0) {
            i = i0 + i1;
            index += i1 * width;
          }
          sign = decodeSignBit(i, j, index);
          coefficentsSign[index] = sign;
          coefficentsMagnitude[index] = 1;
          setNeighborsSignificance(i, j, index);
          processingFlags[index] |= firstMagnitudeBitMask;
          index = index0;
          for (var i2 = i0; i2 <= i; i2++, index += width) {
            bitsDecoded[index]++;
          }
          i1++;
        }
        for (i = i0 + i1; i < iNext; i++, index += width) {
          if (coefficentsMagnitude[index] != 0 ||
              (processingFlags[index] & processedMask) != 0) {
            continue;
          }
          final contextLabel = contextLabelTable[neighborsSignificance[index]];
          final decision = decoder.readBit(contexts, contextLabel);
          if (decision == 1) {
            sign = decodeSignBit(i, j, index);
            coefficentsSign[index] = sign;
            coefficentsMagnitude[index] = 1;
            setNeighborsSignificance(i, j, index);
            processingFlags[index] |= firstMagnitudeBitMask;
          }
          bitsDecoded[index]++;
        }
      }
      i0 = iNext;
    }
  }

  void checkSegmentationSymbol() {
    final symbol = (decoder.readBit(contexts, uniformContext) << 3) |
        (decoder.readBit(contexts, uniformContext) << 2) |
        (decoder.readBit(contexts, uniformContext) << 1) |
        decoder.readBit(contexts, uniformContext);
    if (symbol != 0xa) throw JpxError('Invalid segmentation symbol');
  }
}

abstract class _Transform {
  Map<String, dynamic> calculate(
    List<Map<String, dynamic>> subbands,
    int u0,
    int v0,
  ) {
    var ll = subbands[0];
    for (var i = 1; i < subbands.length; i++) {
      ll = iterate(ll, subbands[i], u0, v0);
    }
    return ll;
  }

  void extend(Float32List buffer, int offset, int size) {
    var i1 = offset - 1;
    var j1 = offset + 1;
    var i2 = offset + size - 2;
    var j2 = offset + size;
    buffer[i1--] = buffer[j1++];
    buffer[j2++] = buffer[i2--];
    buffer[i1--] = buffer[j1++];
    buffer[j2++] = buffer[i2--];
    buffer[i1--] = buffer[j1++];
    buffer[j2++] = buffer[i2--];
    buffer[i1] = buffer[j1];
    buffer[j2] = buffer[i2];
  }

  Map<String, dynamic> iterate(
    Map<String, dynamic> ll,
    Map<String, dynamic> hlLhHh,
    int u0,
    int v0,
  ) {
    final llWidth = _i(ll['width']);
    final llHeight = _i(ll['height']);
    final llItems = ll['items'] as Float32List;
    final width = _i(hlLhHh['width']);
    final height = _i(hlLhHh['height']);
    final items = hlLhHh['items'] as Float32List;

    var k = 0;
    for (var i = 0; i < llHeight; i++) {
      var l = i * 2 * width;
      for (var j = 0; j < llWidth; j++, k++, l += 2) {
        items[l] = llItems[k];
      }
    }

    const bufferPadding = 4;
    final rowBuffer = Float32List(width + 2 * bufferPadding);
    if (width == 1) {
      if ((u0 & 1) != 0) {
        for (var v = 0, index = 0; v < height; v++, index += width) {
          items[index] *= 0.5;
        }
      }
    } else {
      for (var v = 0, index = 0; v < height; v++, index += width) {
        rowBuffer.setRange(bufferPadding, bufferPadding + width, items, index);
        extend(rowBuffer, bufferPadding, width);
        filter(rowBuffer, bufferPadding, width);
        items.setRange(index, index + width, rowBuffer, bufferPadding);
      }
    }

    var numBuffers = 16;
    final colBuffers = List<Float32List>.generate(
      numBuffers,
      (_) => Float32List(height + 2 * bufferPadding),
      growable: false,
    );
    var currentBuffer = 0;
    final llEnd = bufferPadding + height;
    if (height == 1) {
      if ((v0 & 1) != 0) {
        for (var u = 0; u < width; u++) {
          items[u] *= 0.5;
        }
      }
    } else {
      for (var u = 0; u < width; u++) {
        if (currentBuffer == 0) {
          numBuffers = math.min(width - u, numBuffers);
          var sourceIndex = u;
          for (var l = bufferPadding; l < llEnd; sourceIndex += width, l++) {
            for (var b = 0; b < numBuffers; b++) {
              colBuffers[b][l] = items[sourceIndex + b];
            }
          }
          currentBuffer = numBuffers;
        }
        currentBuffer--;
        final buffer = colBuffers[currentBuffer];
        extend(buffer, bufferPadding, height);
        filter(buffer, bufferPadding, height);
        if (currentBuffer == 0) {
          var targetIndex = u - numBuffers + 1;
          for (var l = bufferPadding; l < llEnd; targetIndex += width, l++) {
            for (var b = 0; b < numBuffers; b++) {
              items[targetIndex + b] = colBuffers[b][l];
            }
          }
        }
      }
    }
    return <String, dynamic>{'width': width, 'height': height, 'items': items};
  }

  void filter(Float32List x, int offset, int length);
}

class _IrreversibleTransform extends _Transform {
  @override
  void filter(Float32List x, int offset, int length) {
    final len = length >> 1;
    const alpha = -1.586134342059924;
    const beta = -0.052980118572961;
    const gamma = 0.882911075530934;
    const delta = 0.443506852043971;
    const kScale = 1.230174104914001;
    const kInverse = 1 / kScale;

    var j = offset - 3;
    for (var n = len + 4; n > 0; n--, j += 2) {
      x[j] *= kInverse;
    }

    j = offset - 2;
    var current = delta * x[j - 1];
    for (var n = len + 3; n > 0; n--, j += 2) {
      final next = delta * x[j + 1];
      x[j] = kScale * x[j] - current - next;
      current = next;
    }

    j = offset - 1;
    current = gamma * x[j - 1];
    for (var n = len + 2; n > 0; n--, j += 2) {
      final next = gamma * x[j + 1];
      x[j] -= current + next;
      current = next;
    }

    j = offset;
    current = beta * x[j - 1];
    for (var n = len + 1; n > 0; n--, j += 2) {
      final next = beta * x[j + 1];
      x[j] -= current + next;
      current = next;
    }

    j = offset + 1;
    current = alpha * x[j - 1];
    for (var n = len; n > 0; n--, j += 2) {
      final next = alpha * x[j + 1];
      x[j] -= current + next;
      current = next;
    }
  }
}

class _ReversibleTransform extends _Transform {
  @override
  void filter(Float32List x, int offset, int length) {
    final len = length >> 1;
    var j = offset;
    var n = len + 1;
    while (n-- > 0) {
      x[j] -= (x[j - 1] + x[j + 1] + 2).truncate() >> 2;
      j += 2;
    }
    j = offset + 1;
    n = len;
    while (n-- > 0) {
      x[j] += (x[j - 1] + x[j + 1]).truncate() >> 1;
      j += 2;
    }
  }
}
