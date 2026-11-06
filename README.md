# trade-atlas

A live, interactive 3D globe of global maritime trade, written in Zig. Ports
are nodes, routes follow real sea lanes, and disruptions (blocked
chokepoints, storms, sanctions) are detected from live data and explained.

> **Status: Milestone 0 (data reality check), done.** Every data source
> has been fetched for real through our own Zig HTTPS/WebSocket client, its
> schema recorded, and its parser tested against the captured response.
> No globe yet; that is Milestone 1.

## Run it

Requires [Zig 0.17.1](https://ziglang.org/download/).

```sh
zig build test                 # 46 tests: unit tests + parsers against real responses
zig build run -- sources       # list all data sources and their freshness class
zig build run -- probe         # fetch a real sample from every source into fixtures/
zig build run -- probe usgs    # ... or just one
```

API keys (free) are read from environment variables, never from files in
the repo:

| variable | sign up |
|---|---|
| `AISSTREAM_API_KEY` | https://aisstream.io (GitHub login) |
| `COMTRADE_API_KEY` | https://comtradedeveloper.un.org (free "comtrade - v1" product) |
| `FRED_API_KEY` | https://fredaccount.stlouisfed.org/apikeys |
| `CENSUS_API_KEY` (optional) | https://api.census.gov/data/key_signup.html (activate via e-mail) |

Sources that need a missing key are reported as `skipped`, not as failures.

## Layout

```
src/
  main.zig            CLI (sources, probe; later: serve)
  probe.zig           fetch + validate + record one real sample per source
  net/https.zig       HTTPS/1.1 client: CONNECT proxy, TLS, chunked, gzip, redirects
  net/websocket.zig   RFC 6455 client (AISStream)
  util/zip.zig        in-memory zip reader (GDELT 15-minute files)
  util/time.zig       date formats used by the sources -> Unix seconds UTC
  ingest/registry.zig every source: what, how fresh, licence, key, requirement
  ingest/*.zig        one parser per source, typed to the real field names
  fixture_tests.zig   parser tests against fixtures/
fixtures/<id>/        FIXTURES: real responses + schema.txt + PROBE.md (tests only)
docs/SOURCES.md       verified source table and what the probes revealed
docs/DECISIONS.md     agreed design decisions, non-Zig glue list, limitations
```

## Milestone 0 report

**Works**
- 16 of 18 sources fetched and parsed in Zig. See [docs/SOURCES.md](docs/SOURCES.md).
- Live AIS over WebSocket (AISStream) streams into Zig.
- Our own HTTPS client works through HTTP CONNECT proxies (needed for
  cloud/university networks; Zig's standard client does not do this yet).

**Failing / blocked**
- `census_porths`: key rejected (needs e-mail activation).
- `nga_msi`: NGA portal under maintenance (HTTP 503).

**Faked**
- Nothing. Fixtures are real responses, used only in tests.

**Wrong / risky**
- No request timeouts yet: a server that stalls can hang a probe (Zig 0.17.1
  limitation; fix planned in M1 via task cancellation).
- `comtrade.mode()` treats MOT code 2100 as sea from the UN code list; no
  sea row has been seen in a sample yet.

**Least sure about**
- How much of the 2026 Hormuz transit collapse in PortWatch is real traffic
  loss and how much is ships going dark / GPS jamming (see SOURCES.md §3).
- Whether AISStream's Gulf coverage gap is permanent or temporary (one
  90-second sample).

## Data credits

IMF PortWatch; UN Comtrade; US Census Bureau; FRED, Federal Reserve Bank of
St. Louis; The GDELT Project; GDACS (EC JRC, UN OCHA); USGS; OpenSanctions
(CC BY-NC 4.0); Bailey, Strezhnev & Voeten UNGA voting data (CC0); Eurostat
SeaRoute/MARNET (EUPL 1.2); Natural Earth; AISStream.io; NGA MSI.
