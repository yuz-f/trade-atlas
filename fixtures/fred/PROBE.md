# Probe: fred

> FIXTURE. Real response captured by `atlas probe` for tests and schema checks.
> Not used as live data by the running system.

| field | value |
|---|---|
| source | FRED (St. Louis Fed) |
| url | `https://api.stlouisfed.org/fred/series/observations?series_id=DEXCHUS&api_key=<REDACTED>&file_type=json&sort_order=desc&limit=5` |
| outcome | ok |
| http status | 200 |
| bytes | 756 |
| fetched at (UTC) | 2026-11-06T07:22:12Z |
| newest data time (UTC) | 2026-11-03T00:00:00Z |
| freshness class | NEAR-LIVE |
| note | DCOILBRENTEU 2026-11-03=107.03; DCOILWTICO 2026-11-03=99.64; PCU483111483111 2026-09-01=534.796; DEXCHUS 2026-10-30=6.6538;  |
