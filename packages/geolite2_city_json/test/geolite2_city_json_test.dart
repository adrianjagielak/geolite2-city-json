import 'dart:convert';

import 'package:geolite2_city_json/geolite2_city_json.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('parseIpv4', () {
    test('parses a dotted quad', () {
      expect(parseIpv4('8.8.4.4'), [8, 8, 4, 4]);
    });

    test('rejects malformed input', () {
      expect(() => parseIpv4('8.8.8'), throwsFormatException);
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
          // C=3: leading gap then data
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
      expect(decodeSixteen(file, 2, 200)?.city, isNull); // r[2]
    });

    test('gap run (index -1) returns null', () {
      expect(decodeSixteen(file, 3, 10), isNull); // before .128
      expect(decodeSixteen(file, 3, 200)?.country, 'US'); // r[0]
    });

    test('third octet beyond the array returns null', () {
      expect(decodeSixteen(file, 200, 1), isNull);
    });
  });

  group('Geolite2City.lookup', () {
    http.Response respond(Uri url) {
      if (url.path.endsWith('/data/8/8.json')) {
        return http.Response(
          jsonEncode({
            'r': [
              {'c': 'US', 'y': 37.751, 'x': -97.822},
            ],
            'c': [for (var i = 0; i < 256; i++) 0],
          }),
          200,
        );
      }
      return http.Response('Not found', 404);
    }

    test('resolves an address', () async {
      final geo =
          Geolite2City(httpClient: MockClient((r) async => respond(r.url)));
      final g = await geo.lookup('8.8.8.8');
      expect(g?.country, 'US');
      expect(g?.lon, -97.822);
      geo.close();
    });

    test('returns null on 404', () async {
      final geo =
          Geolite2City(httpClient: MockClient((r) async => respond(r.url)));
      expect(await geo.lookup('9.9.9.9'), isNull);
      geo.close();
    });

    test('caches results and coalesces concurrent calls to one request',
        () async {
      var calls = 0;
      final geo = Geolite2City(
        httpClient: MockClient((r) async {
          calls++;
          return respond(r.url);
        }),
      );

      // Two concurrent calls for the same IP -> a single request.
      final both =
          await Future.wait([geo.lookup('8.8.8.8'), geo.lookup('8.8.8.8')]);
      expect(both[0], both[1]);

      // A later call is served from cache -> still a single request.
      await geo.lookup('8.8.8.8');
      expect(calls, 1);
      geo.close();
    });

    test('rejects a malformed address', () {
      final geo =
          Geolite2City(httpClient: MockClient((r) async => respond(r.url)));
      expect(geo.lookup('nope'), throwsFormatException);
      geo.close();
    });
  });
}
