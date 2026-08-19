## 0.1.0

- Initial release.
- `geolocate(ip)` convenience function and a reusable `Geolite2City` client.
- In-memory LRU cache of the last N addresses and per-IP request coalescing.
- Pure `decodeSixteen(...)` / `parseIpv4(...)` helpers for offline use and tests.
- Sole runtime dependency: `package:http`.
