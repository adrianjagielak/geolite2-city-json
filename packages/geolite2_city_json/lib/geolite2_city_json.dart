/// A tiny IPv4 geolocation client for the free
/// [geolite2-city-json](https://github.com/adrianjagielak/geolite2-city-json)
/// static JSON dataset (derived from MaxMind's GeoLite2-City).
///
/// The dataset is a tree of small JSON files served from a CDN — no server, no
/// API key. This library fetches the one file an address needs, decodes it, and
/// returns a [GeoLocation]. Results for the last few addresses are cached in
/// memory and concurrent lookups of the same address share a single request.
///
/// ```dart
/// final loc = await geolocate('8.8.8.8');
/// print(loc?.country); // US
/// ```
///
/// The only runtime dependency is `package:http`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Default CDN base URL for the published dataset (the `master` branch via
/// jsDelivr). Override it via [Geolite2City.baseUrl] to pin a tag/commit or to
/// use `raw.githubusercontent.com`.
const String kDefaultBaseUrl =
    'https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master';

/// A resolved location for an IPv4 address.
///
/// Every field is nullable — GeoLite2-City often knows only some of them (for
/// example a country but no city). A lookup that finds no data at all returns
/// `null` rather than an all-null [GeoLocation].
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

/// Client for the `geolite2-city-json` dataset.
///
/// Create one instance and reuse it. [lookup] caches the last [cacheSize]
/// addresses and coalesces concurrent lookups of the same address into a single
/// network request. Call [close] when finished, unless you passed your own
/// [http.Client] (then close that yourself).
class Geolite2City {
  Geolite2City({
    http.Client? httpClient,
    this.baseUrl = kDefaultBaseUrl,
    this.cacheSize = 10,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// Base URL that the `/data/<A>/<B>.json` files are fetched from.
  final String baseUrl;

  /// Maximum number of most-recently-used addresses kept in memory.
  final int cacheSize;

  final http.Client _http;
  final bool _ownsHttp;

  // Most-recently-used cache; insertion order encodes recency. A stored value
  // may be null (a cached "no data" answer, so we don't refetch it).
  final Map<String, GeoLocation?> _cache = <String, GeoLocation?>{};

  // In-flight lookups, so N concurrent calls for one IP make one request.
  final Map<String, Future<GeoLocation?>> _inflight =
      <String, Future<GeoLocation?>>{};

  /// Resolves [ip] (a dotted-quad IPv4 string like `"8.8.8.8"`) to a
  /// [GeoLocation], or `null` if the dataset has no data for it.
  ///
  /// Completes with a [FormatException] if [ip] is not a valid IPv4 address,
  /// or an [http.ClientException] on an unexpected HTTP status.
  Future<GeoLocation?> lookup(String ip) {
    if (_cache.containsKey(ip)) {
      final value = _cache.remove(ip); // re-insert to mark most-recently-used
      _cache[ip] = value;
      return Future<GeoLocation?>.value(value);
    }
    return _inflight.putIfAbsent(
      ip,
      // NB: the whenComplete callback must NOT return the value of
      // `_inflight.remove` (which is this very future) — whenComplete would
      // then wait on it and deadlock. Keep it a statement, not an expression.
      () => _fetch(ip).whenComplete(() {
        _inflight.remove(ip);
      }),
    );
  }

  /// Releases the underlying [http.Client] if this instance created it.
  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<GeoLocation?> _fetch(String ip) async {
    final result = await _resolve(ip);
    _cache[ip] = result;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first); // evict least-recently-used
    }
    return result;
  }

  Future<GeoLocation?> _resolve(String ip) async {
    final octets = parseIpv4(ip);
    final url = Uri.parse('$baseUrl/data/${octets[0]}/${octets[1]}.json');
    final res = await _http.get(url);
    if (res.statusCode == 404) return null; // no data for this /16
    if (res.statusCode != 200) {
      throw http.ClientException('Unexpected status ${res.statusCode}', url);
    }
    final file = jsonDecode(res.body) as Map<String, dynamic>;
    return decodeSixteen(file, octets[2], octets[3]);
  }
}

/// Decodes a single `/16` file body (`data/<A>/<B>.json`) for third and fourth
/// octets [c] and [d]. Pure (no I/O) — exposed for testing and offline use.
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

Geolite2City? _shared;

/// Resolves [ip] to a [GeoLocation] (or `null`) using a lazily-created shared
/// [Geolite2City]. Convenient for simple apps; create your own [Geolite2City]
/// when you need to configure or dispose the [http.Client].
Future<GeoLocation?> geolocate(String ip) =>
    (_shared ??= Geolite2City()).lookup(ip);
