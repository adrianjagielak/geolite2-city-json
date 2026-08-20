## 1.1.0

- Add `accuracyKm` to `GeoLocation` — the radius in km around lat/lon the address
  is likely within (MaxMind's `accuracy_radius`).

## 1.0.0

- Initial release.
- `geolocate(ip)` resolves an IPv4 address to a `GeoLocation`.
- In-memory LRU cache of the last few addresses and per-IP request coalescing.
- Pure `decodeSixteen(...)` / `parseIpv4(...)` helpers for offline use and tests.
- Only runtime dependency is `package:http`.
