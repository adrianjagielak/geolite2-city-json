# ip_geolocate

IPv4 geolocation for Dart & Flutter, backed by the free
[geolite2-city-json](https://github.com/adrianjagielak/geolite2-city-json)
dataset (derived from MaxMind's GeoLite2-City) served as static JSON from a CDN.

## Install

```console
dart pub add ip_geolocate
```

## Usage

```dart
import 'package:ip_geolocate/ip_geolocate.dart';

Future<void> main() async {
  final loc = await geolocate('8.8.8.8');
  print(loc?.country);              // US
  print('${loc?.lat}, ${loc?.lon}'); // 37.751, -97.822
}
```

`geolocate` returns a `GeoLocation?` — `null` means the dataset has no data for
the address. The last few lookups are cached in memory, and concurrent lookups
of the same address share a single request.

Any field of `GeoLocation` may be `null`:

| field | type | meaning |
| --- | --- | --- |
| `country` | `String?` | ISO 3166-1 alpha-2, e.g. `US` |
| `region`  | `String?` | ISO 3166-2 subdivision, e.g. `CA` |
| `city`    | `String?` | English city name |
| `lat`     | `double?` | latitude |
| `lon`     | `double?` | longitude |

Non-IPv4 input throws a `FormatException`.

## Attribution

Uses GeoLite2 data created by MaxMind, available from
[https://www.maxmind.com](https://www.maxmind.com), under the
[GeoLite2 EULA](https://www.maxmind.com/en/geolite2/eula). Package code is
MIT-licensed. Not affiliated with or endorsed by MaxMind.
