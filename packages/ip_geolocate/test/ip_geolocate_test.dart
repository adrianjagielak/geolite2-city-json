import 'package:ip_geolocate/ip_geolocate.dart';
import 'package:test/test.dart';

void main() {
  group('parseIpv4', () {
    test('parses a dotted quad', () {
      expect(parseIpv4('8.8.4.4'), [8, 8, 4, 4]);
      expect(parseIpv4('0.0.0.0'), [0, 0, 0, 0]);
      expect(parseIpv4('255.255.255.255'), [255, 255, 255, 255]);
    });

    test('rejects malformed input', () {
      expect(() => parseIpv4('8.8.8'), throwsFormatException);
      expect(() => parseIpv4('8.8.8.8.8'), throwsFormatException);
      expect(() => parseIpv4('8.8.8.256'), throwsFormatException);
      expect(() => parseIpv4('a.b.c.d'), throwsFormatException);
      expect(() => parseIpv4('1.2.3.'), throwsFormatException);
    });
  });

  group('decodeSixteen', () {
    final file = <String, dynamic>{
      'r': [
        {'c': 'US', 'y': 37.75, 'x': -97.82},
        {'c': 'JP', 'r': '13', 't': 'Tokyo', 'y': 35.68, 'x': 139.69},
        {'c': 'JP', 'y': 35.69, 'x': 139.69},
      ],
      'c': [
        0, // C=0: uniform /24 -> r[0]
        null, // C=1: no data
        [
          // C=2: split /24
          [0, 2],
          [53, 1],
          [54, 2],
        ],
        [
          // C=3: leading gap, then data at .128
          [0, -1],
          [128, 0],
        ],
      ],
    };

    test('uniform /24 resolves to its record', () {
      final g = decodeSixteen(file, 0, 123);
      expect(g?.country, 'US');
      expect(g?.lat, 37.75);
      expect(g?.lon, -97.82);
      expect(g?.city, isNull);
    });

    test('no-data slot returns null', () {
      expect(decodeSixteen(file, 1, 0), isNull);
    });

    test('split /24 picks the run covering the octet', () {
      expect(decodeSixteen(file, 2, 52)?.city, isNull); // r[2]
      expect(decodeSixteen(file, 2, 53)?.city, 'Tokyo'); // r[1]
      expect(decodeSixteen(file, 2, 54)?.city, isNull); // r[2]
      expect(decodeSixteen(file, 2, 200)?.city, isNull); // r[2]
    });

    test('gap run (index -1) returns null', () {
      expect(decodeSixteen(file, 3, 10), isNull); // before .128
      expect(decodeSixteen(file, 3, 200)?.country, 'US'); // r[0]
    });

    test('third octet beyond the array returns null', () {
      expect(decodeSixteen(file, 200, 1), isNull);
    });

    test('maps compact keys to GeoLocation fields', () {
      final g = decodeSixteen(file, 2, 53);
      expect(
        g,
        const GeoLocation(
          country: 'JP',
          region: '13',
          city: 'Tokyo',
          lat: 35.68,
          lon: 139.69,
        ),
      );
    });
  });
}
