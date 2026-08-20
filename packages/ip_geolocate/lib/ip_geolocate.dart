/// IPv4 geolocation using the free
/// [geolite2-city-json](https://github.com/adrianjagielak/geolite2-city-json)
/// dataset (MaxMind GeoLite2-City), served as static JSON from a CDN.
///
/// ```dart
/// final loc = await geolocate('8.8.8.8');
/// print(loc?.country); // US
/// ```
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const _baseUrl =
    'https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master';

/// A location resolved for an IPv4 address. Every field may be null — the
/// dataset often knows only some of them (e.g. a country but no city).
class GeoLocation {
  /// ISO 3166-1 alpha-2 country code, e.g. `US`.
  final String? country;

  /// ISO 3166-2 subdivision (region / state / province) code, e.g. `CA`.
  final String? region;

  /// English city name, e.g. `Ashburn`.
  final String? city;

  /// Latitude in decimal degrees.
  final double? lat;

  /// Longitude in decimal degrees.
  final double? lon;

  const GeoLocation({
    this.country,
    this.region,
    this.city,
    this.lat,
    this.lon,
  });

  @override
  String toString() => 'GeoLocation(country: $country, region: $region, '
      'city: $city, lat: $lat, lon: $lon)';

  @override
  bool operator ==(Object other) =>
      other is GeoLocation &&
      other.country == country &&
      other.region == region &&
      other.city == city &&
      other.lat == lat &&
      other.lon == lon;

  @override
  int get hashCode => Object.hash(country, region, city, lat, lon);
}

// Cache of the last few resolved addresses (insertion order encodes recency).
const _cacheLimit = 10;
final Map<String, GeoLocation?> _cache = {};

// Concurrent lookups of the same address share one request.
final Map<String, Future<GeoLocation?>> _inflight = {};

/// Resolves [ip] (a dotted-quad IPv4 string like `'8.8.8.8'`) to a
/// [GeoLocation], or `null` if the dataset has no data for it.
///
/// The last few addresses are cached in memory, and concurrent calls for the
/// same address share a single request. Throws a [FormatException] for
/// non-IPv4 input.
Future<GeoLocation?> geolocate(String ip) {
  if (_cache.containsKey(ip)) {
    final value = _cache.remove(ip);
    _cache[ip] = value; // move to most-recently-used
    return Future.value(value);
  }
  final pending = _inflight[ip];
  if (pending != null) return pending;

  // Keep the cleanup a statement: returning `_inflight.remove(ip)` (this very
  // future) would make whenComplete await itself and deadlock.
  final future = _load(ip).whenComplete(() {
    _inflight.remove(ip);
  });
  _inflight[ip] = future;
  return future;
}

Future<GeoLocation?> _load(String ip) async {
  final octets = parseIpv4(ip);
  final url = Uri.parse('$_baseUrl/data/${octets[0]}/${octets[1]}.json');
  final res = await http.get(url);

  GeoLocation? result;
  if (res.statusCode == 200) {
    final file = jsonDecode(res.body) as Map<String, dynamic>;
    result = decodeSixteen(file, octets[2], octets[3]);
  } else if (res.statusCode != 404) {
    throw http.ClientException('Unexpected status ${res.statusCode}', url);
  }

  _cache[ip] = result;
  while (_cache.length > _cacheLimit) {
    _cache.remove(_cache.keys.first); // evict least-recently-used
  }
  return result;
}

/// Decodes a single `/16` file body (`data/<A>/<B>.json`) for third and fourth
/// octets [c] and [d]. Pure (no I/O) — useful for offline decoding and tests.
///
/// The file is `{"r": [records...], "c": [slot0..slot255]}`, where a slot is
/// `null` (no data), an `int` index into `r`, or a run-list
/// `[[startOctet, recordIndex], ...]` for a split /24 (`recordIndex == -1`
/// marks an octet range with no data).
GeoLocation? decodeSixteen(Map<String, dynamic> file, int c, int d) {
  final slots = file['c'] as List<dynamic>;
  final slot = (c >= 0 && c < slots.length) ? slots[c] : null;

  int? recordIndex;
  if (slot is int) {
    recordIndex = slot;
  } else if (slot is List) {
    // Run-list: the last run whose start octet is <= d wins.
    for (final run in slot) {
      final start = (run as List)[0] as int;
      if (start <= d) {
        recordIndex = run[1] as int;
      } else {
        break;
      }
    }
  }
  if (recordIndex == null || recordIndex < 0) return null;

  final rec = (file['r'] as List<dynamic>)[recordIndex] as Map<String, dynamic>;
  return GeoLocation(
    country: rec['c'] as String?,
    region: rec['r'] as String?,
    city: rec['t'] as String?,
    lat: (rec['y'] as num?)?.toDouble(),
    lon: (rec['x'] as num?)?.toDouble(),
  );
}

/// Parses a dotted-quad IPv4 string into four octets (each 0–255).
///
/// Throws a [FormatException] if [ip] is not a valid IPv4 address.
List<int> parseIpv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) {
    throw FormatException('Not an IPv4 address', ip);
  }
  final octets = List<int>.filled(4, 0);
  for (var i = 0; i < 4; i++) {
    final value = int.tryParse(parts[i]);
    if (value == null || value < 0 || value > 255) {
      throw FormatException('Not an IPv4 address', ip);
    }
    octets[i] = value;
  }
  return octets;
}
