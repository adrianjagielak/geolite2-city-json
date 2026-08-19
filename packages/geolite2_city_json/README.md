# geolite2_city_json

Tiny IPv4 geolocation for Dart & Flutter, backed by the free
[**geolite2-city-json**](https://github.com/adrianjagielak/geolite2-city-json)
dataset — a CDN-hosted tree of static JSON files derived from MaxMind's
GeoLite2-City. **No server, no API key, no rate limits.**

- One call: `await geolocate('8.8.8.8')`.
- In-memory LRU cache of the last few addresses.
- Concurrent lookups of the same address share a single request.
- Sole runtime dependency: [`http`](https://pub.dev/packages/http).

## Install

```console
dart pub add geolite2_city_json
```

## Usage

```dart
import 'package:geolite2_city_json/geolite2_city_json.dart';

Future<void> main() async {
  final loc = await geolocate('8.8.8.8');
  print(loc?.country); // US
  print(loc?.lat);     // 37.751

  // Reusable client with its own cache + http.Client lifecycle:
  final geo = Geolite2City(cacheSize: 100);
  final tokyo = await geo.lookup('1.1.125.53');
  print('${tokyo?.city}, ${tokyo?.country}'); // Tokyo, JP
  geo.close();
}
```

`lookup` / `geolocate` return a `GeoLocation?` — `null` means the dataset has no
data for that address (served as an HTTP 404). Any field may be `null`:

| field | type | meaning |
| --- | --- | --- |
| `country` | `String?` | ISO 3166-1 alpha-2, e.g. `US` |
| `region`  | `String?` | ISO 3166-2 subdivision, e.g. `CA` |
| `city`    | `String?` | English city name |
| `lat`     | `double?` | latitude |
| `lon`     | `double?` | longitude |

A `FormatException` is thrown for non-IPv4 input; an `http.ClientException` for
an unexpected HTTP status.

## Notes

- **IPv4 only.** City-level accuracy is approximate (GeoLite2 free tier); treat
  `lat`/`lon` as area centroids.
- By default data is read from the `@master` branch via jsDelivr (cached ~12 h).
  Pass `Geolite2City(baseUrl: ...)` to pin a tag/commit for immutable caching.
- The `geolocate` convenience function uses a shared client that is never
  closed; for tighter control construct your own `Geolite2City` and `close()` it.

## Attribution

This package consumes GeoLite2 data created by MaxMind, available from
[https://www.maxmind.com](https://www.maxmind.com). Use of the data is subject
to the [GeoLite2 EULA](https://www.maxmind.com/en/geolite2/eula). Package code is
MIT-licensed. Not affiliated with or endorsed by MaxMind.
