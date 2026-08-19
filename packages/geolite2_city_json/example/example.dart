import 'package:geolite2_city_json/geolite2_city_json.dart';

Future<void> main() async {
  // Simplest form: a top-level function backed by a shared client.
  final g = await geolocate('8.8.8.8');
  print(g);
  // -> GeoLocation(country: US, region: null, city: null, lat: 37.751, lon: -97.822)

  // Full control: custom cache size and explicit lifecycle.
  final geo = Geolite2City(cacheSize: 100);
  final loc = await geo.lookup('77.236.25.1');
  if (loc != null) {
    print(
        '${loc.city}, ${loc.region}, ${loc.country} @ ${loc.lat}, ${loc.lon}');
    // -> Gdansk, 22, PL @ 54.3947, 18.5926
  }
  geo.close();
}
