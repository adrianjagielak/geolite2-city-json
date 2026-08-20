# geolite2-city-json

Free, serverless IP geolocation as **static JSON files** — no API keys, no rate
limits, no backend. The MaxMind **GeoLite2-City** database is split into a tree
of small JSON files, refreshed daily by a GitHub Action, and served straight
from the CDN.

Look up any IPv4 address by fetching one small file and indexing into it.

```
https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master/data/<A>/<B>.json
```

for the address `A.B.C.D` — e.g. `8.8.8.8` → `data/8/8.json`.

> **Attribution.** This product includes GeoLite2 data created by MaxMind,
> available from [https://www.maxmind.com](https://www.maxmind.com). If you use
> this dataset you must keep this attribution (see [License](#license)).

---

## Why files are grouped by /16 (and not one file per /24)

The obvious layout — one file per /24 at `data/A/B/C.json`, keyed by the last
octet — turns out to be impossible in practice. Measured against a real
GeoLite2-City build:

| Layout | Files | Size | Feasible? |
| --- | --- | --- | --- |
| `data/A/B/C.json`, keyed by octet (literal per-IP) | **14,404,356** | **~221 GiB** | ❌ |
| `data/A/B/C.json`, one record per /24 | **14,404,356** | ~1.2 GiB | ❌ (file **count**) |
| **`data/A/B.json` per /16, compact + lossless** | **56,391** | **~110 MiB** | ✅ |

The database stores a *single* record for large blocks (a whole /20, /16, …),
so a per-octet layout would store the same fact millions of times, and 14.4M
files would break `git`, `actions/checkout` (inodes), GitHub repo limits, and
jsDelivr. Grouping by **/16** with per-file de-duplication keeps every exact
per-IP answer while producing ~56k files that pack to ~25 MiB in git.

---

## File format

Each file `data/A/B.json` describes the `/16` block `A.B.0.0/16`:

```json
{
  "r": [ {"c":"PL","r":"22","t":"Gdansk","y":54.3947,"x":18.5926,"a":5}, ... ],
  "c": [ slot0, slot1, ..., slot255 ]
}
```

- **`r`** — the distinct records used in this /16 (a per-file lookup table, so
  each record is written once).
- **`c`** — an array indexed by the **third octet `C`**. Each slot is one of:
  - `null` — that /24 has no data;
  - an **integer** `i` — the whole /24 resolves to `r[i]` (the common case);
  - an **array of runs** `[[startOctet, ri], ...]` — the /24 is split into
    sub-ranges. Runs are sorted by `startOctet`; run *k* covers octets
    `[startOctet_k, startOctet_{k+1})`. `ri = -1` means "no data" for that
    range, otherwise the record is `r[ri]`.

A record uses single-letter keys (it is stored millions of times) and omits
absent fields:

| key | field | meaning |
| --- | --- | --- |
| `c` | country | ISO 3166-1 alpha-2 code (falls back to the registered country) |
| `r` | region  | ISO 3166-2 top-level subdivision (state / province) *(optional)* |
| `t` | city    | English city name *(optional)* |
| `y` | lat     | latitude *(optional)* |
| `x` | lon     | longitude *(optional)* |
| `a` | accuracy | radius of `y`/`x` in km *(optional)* |

`y`/`x` follow the map-axis convention (latitude = y-axis, longitude = x-axis).
Note the two levels: the **top-level** `r` is the records array, while a `r`
*inside a record* is its region.

`data/meta.json` carries the source build date and counts.

### Lookup algorithm

For `A.B.C.D`: fetch `data/A/B.json`, take `slot = c[C]`. If it's `null`/absent
→ no data. If it's a number → `r[slot]`. If it's a run-list → find the last run
whose `startOctet ≤ D` and use its record index.

---

## Usage

The lookup is deliberately trivial: fetch `data/A/B.json`, read `c[C]`, and (for
split /24s) pick the run covering `D`. Clients in a few languages below.

### Dart / Flutter

A ready-made package lives in [`packages/ip_geolocate/`](packages/ip_geolocate)
(in-memory cache, per-IP request coalescing, `http` as its only dependency):

```dart
import 'package:ip_geolocate/ip_geolocate.dart';

final loc = await geolocate('8.8.8.8');
print('${loc?.city}, ${loc?.region}, ${loc?.country}'); // -> null, null, US
```

### JavaScript (browser or Node 18+)

```js
async function geolocate(ip) {
  const [A, B, C, D] = ip.split('.').map(Number);
  const base = 'https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master';
  const res = await fetch(`${base}/data/${A}/${B}.json`);
  if (!res.ok) return null;                 // 404 => no data for this /16
  const { r, c } = await res.json();

  const slot = c[C];
  if (slot == null) return null;
  if (typeof slot === 'number') return r[slot];

  // split /24: last run with startOctet <= D
  let lo = 0, hi = slot.length - 1, ans = 0;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    if (slot[m][0] <= D) { ans = m; lo = m + 1; } else hi = m - 1;
  }
  const ri = slot[ans][1];
  return ri < 0 ? null : r[ri];
}

console.log(await geolocate('8.8.8.8'));
// { c: 'US', y: 37.751, x: -97.822, a: 1000 }   (c=country, r=region, t=city, y=lat, x=lon, a=accuracy km)
```

### Python 3

```python
import bisect, json, urllib.request

BASE = "https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master"

def geolocate(ip):
    A, B, C, D = map(int, ip.split("."))
    try:
        with urllib.request.urlopen(f"{BASE}/data/{A}/{B}.json") as f:
            data = json.load(f)
    except urllib.error.HTTPError:
        return None
    c = data["c"]
    slot = c[C] if C < len(c) else None
    if slot is None:
        return None
    if isinstance(slot, int):
        return data["r"][slot]
    i = bisect.bisect_right([run[0] for run in slot], D) - 1
    ri = slot[i][1]
    return None if ri < 0 else data["r"][ri]

print(geolocate("8.8.8.8"))
# {'c': 'US', 'y': 37.751, 'x': -97.822, 'a': 1000}   (c=country, r=region, t=city, y=lat, x=lon, a=accuracy km)
```

### Shell (curl + jq)

```bash
ip=8.8.8.8; IFS=. read -r A B C D <<< "$ip"
curl -s "https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master/data/$A/$B.json" \
  | jq --argjson C "$C" --argjson D "$D" '
      .c[$C] as $s
      | if   $s == null            then null
        elif ($s | type) == "number" then .r[$s]
        else ([ $s[] | select(.[0] <= $D) ] | last) as $run
             | (if $run[1] < 0 then null else .r[$run[1]] end)
        end'
```

---

## Endpoints & caching

Two equivalent hosts serve the same files:

- **jsDelivr** (recommended): `https://cdn.jsdelivr.net/gh/adrianjagielak/geolite2-city-json@master/data/<A>/<B>.json`
  — global CDN, gzip/brotli, permissive CORS. Branch (`@master`) responses are
  cached for up to ~12 hours; that's fine for a dataset that changes at most a
  few times a week.
- **raw.githubusercontent.com**: `https://raw.githubusercontent.com/adrianjagielak/geolite2-city-json/refs/heads/master/data/<A>/<B>.json`
  — no CDN, tighter GitHub rate limits; handy for quick checks.

To pin a specific snapshot (and get long-lived immutable caching on jsDelivr),
replace `@master` with a commit SHA or tag.

---

## Coverage & accuracy

- **IPv4 only.** IPv6 is not generated.
- City-level location is **approximate** — `y`/`x` (lat/lon) are area centroids, not
  precise positions, and GeoLite2 (the free tier) is less accurate than MaxMind's
  paid GeoIP2. Treat results as best-effort.
- Addresses with no city data still resolve to a country where MaxMind has one;
  addresses MaxMind knows nothing about return `null` / 404.
- Data reflects MaxMind's most recent GeoLite2-City build at generation time
  (see `data/meta.json`).

---

## Local development

```bash
npm ci
npm run fetch     # download + decompress GeoLite2-City.mmdb
npm run build     # walk the DB and write ./data/<A>/<B>.json  (~20s)
npm run verify    # cross-check the JSON tree against the .mmdb (2M sampled IPs)

# or in one step:
npm run generate  # fetch + build
```

The build is deterministic: an unchanged database produces byte-identical
files, so re-running never creates spurious git changes.

---

## How it updates

`.github/workflows/update.yml` runs daily (and on demand via
**workflow_dispatch**): it downloads the latest GeoLite2-City database,
regenerates `data/`, verifies the output, and commits **only if something
changed** — so quiet days cost nothing and don't add commits.

---

## License

- **Code** in this repository: [MIT](./LICENSE).
- **Data** under `data/`: derived from MaxMind's **GeoLite2-City** database and
  subject to the
  [GeoLite2 End User License Agreement](https://www.maxmind.com/en/geolite2/eula).
  You must attribute MaxMind:

  > This product includes GeoLite2 data created by MaxMind, available from
  > [https://www.maxmind.com](https://www.maxmind.com).

This project is not affiliated with or endorsed by MaxMind.
