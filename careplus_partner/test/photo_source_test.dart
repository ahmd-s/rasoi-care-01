import 'dart:typed_data';

import 'package:care_plus_partner/data/api/vision_api.dart';
import 'package:care_plus_partner/features/passport/photo_source.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
]);
final _webp = Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
  0,
]);
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0]);

AiConfig _cfg({int max = 100}) => AiConfig.fromJson({
  'enabled': true,
  'maxImageBytes': max,
  'acceptedTypes': ['image/jpeg', 'image/png'],
});

void main() {
  test('type is judged by content, never by name', () {
    expect(sniffImageType(_jpeg), 'image/jpeg');
    expect(sniffImageType(_png), 'image/png');
    expect(sniffImageType(_webp), 'image/webp');
    expect(sniffImageType(Uint8List.fromList('GIF89a....'.codeUnits)), isNull);
    expect(sniffImageType(Uint8List(0)), isNull);
  });

  test('photoProblem enforces accepted types and the per-image size limit', () {
    expect(photoProblem(_jpeg, _cfg(), number: 1), isNull);
    expect(
      photoProblem(_webp, _cfg(), number: 2),
      contains('Photo 2 is not a supported type'),
    );
    expect(
      photoProblem(
        Uint8List(200)
          ..[0] = 0xFF
          ..[1] = 0xD8
          ..[2] = 0xFF,
        _cfg(),
        number: 3,
      ),
      contains('too large'),
    );
  });
}
