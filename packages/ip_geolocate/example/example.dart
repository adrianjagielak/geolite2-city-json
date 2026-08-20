import 'package:ip_geolocate/ip_geolocate.dart';

Future<void> main() async {
  final loc = await geolocate('8.8.8.8');
  print(loc);
  // -> GeoLocation(country: US, region: null, city: null, lat: 37.751, lon: -97.822)

  final gdansk = await geolocate('77.236.25.1');
  print('${gdansk?.city}, ${gdansk?.country}'); // -> Gdansk, PL
}
