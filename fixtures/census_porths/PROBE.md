# Probe: census_porths

> FIXTURE. Real response captured by `atlas probe` for tests and schema checks.
> Not used as live data by the running system.

| field | value |
|---|---|
| source | US Census international trade (port x HS) |
| url | `https://api.census.gov/data/timeseries/intltrade/imports/porths?get=PORT,PORT_NAME,CTY_NAME,GEN_VAL_MO,VES_VAL_MO,VES_WGT_MO&I_COMMODITY=27&time=2026-08&PORT=5301&key=<REDACTED>` |
| outcome | failed |
| http status | 302 |
| bytes | 0 |
| fetched at (UTC) | 2026-11-06T07:22:12Z |
| newest data time (UTC) | n/a |
| freshness class | LAGGED |
| note | redirected to https://api.census.gov/data/invalid_key.html (key not accepted: activate it via the link in the Census e-mail) |
