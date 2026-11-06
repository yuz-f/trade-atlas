# Data sources (verified)

Every row below was fetched by `atlas probe` (our own Zig HTTPS/WebSocket
client) on **2026-11-06 ~07:20 UTC**. The raw responses are in
`fixtures/<id>/` and the field names our parsers use come from those
responses, not from documentation or memory. Re-run `zig build run -- probe`
to refresh.

Freshness classes used in the UI: **LIVE** (seconds–minutes), **NEAR-LIVE**
(hours–about a week), **LAGGED** (weeks–years), **STATIC** (reference).

## Probe results

| id | what it measures | UI class | newest data on 2026-11-06 | key | licence | supports |
|---|---|---|---|---|---|---|
| `aisstream` | live ship positions + identity/type/destination | LIVE | seconds old | `AISSTREAM_API_KEY` | free beta, no SLA | 2, 3, 5d |
| `portwatch_ports_daily` | daily port calls by vessel type, est. import/export tonnes, ~2,000 ports | NEAR-LIVE | 2026-10-30 (7 d) | – | IMF terms | 4, 5d, Phase 1 target |
| `portwatch_chokepoints_daily` | daily transits + capacity by vessel type, 28 chokepoints | NEAR-LIVE | 2026-10-25 (12 d) | – | IMF terms | 3, 4, 5d, Phase 2 target |
| `portwatch_ports_db` | port reference list (lat/lon, traffic shares) | STATIC | – | – | IMF terms | 3, 4 |
| `portwatch_chokepoints_db` | 28 chokepoints with coordinates | STATIC | – | – | IMF terms | 3 |
| `portwatch_disruptions` | disruption events with affected ports | NEAR-LIVE | 2026-08-14 (newest event in first page) | – | IMF terms | 3, Phase 2 labels |
| `portwatch_tradenow` | monthly AIS-based trade value/volume nowcast per economy | NEAR-LIVE | 2026-09 (~1 month) | – | IMF terms | 4 (benchmark) |
| `comtrade` | bilateral trade value and weight by HS code and mode of transport | LAGGED | 2026-08 for USA/DEU/CHE/JPN; SGP 2026-03; **CHN monthly only to 2024-12** | `COMTRADE_API_KEY` | free tier 500 calls/day | 4, 6 |
| `census_porths` | US imports by port × HS × partner, incl. vessel value/weight | LAGGED | **key rejected** | `CENSUS_API_KEY` | public domain | route-model validation |
| `fred` | Brent, WTI (daily), deep-sea freight PPI (monthly), CNY/USD | NEAR-LIVE | Brent 2026-11-03 = 107.03 USD/bbl | `FRED_API_KEY` | free key | 5a |
| `gdelt_events` | machine-coded news events, tone, Goldstein scale | LIVE | 15 min file, 1,364 events, all 61-column valid | – | open, cite GDELT | 5b, 5c, 6 |
| `gdacs` | global cyclones, quakes, floods, droughts, volcanoes, fires | NEAR-LIVE | modified 2026-11-06 05:57 | – | free, attribute | 5d |
| `usgs` | earthquakes M4.5+ | LIVE | 2026-11-06 02:35 | – | public domain | 5d |
| `opensanctions_maritime` | sanctioned/flagged vessels (IMO, MMSI), owners, operators | NEAR-LIVE | 2026-11-05 15:03 (102,415 targets) | – | **CC BY-NC 4.0** | 5b |
| `unga_votes` | UN General Assembly voting agreement, ideal points 1946–2025 | LAGGED | released 2026-07-30 | – | CC0 | 5b, 6 |
| `marnet` | global sea-lane network, 29,581 segments (20 km) | STATIC | – | – | EUPL 1.2 | 3 (real routes) |
| `natural_earth` | land and coastlines | STATIC | – | – | public domain | 3 |
| `nga_msi` | navigational warnings + piracy reports (ASAM) | NEAR-LIVE | **portal under maintenance (HTTP 503)** | – | public domain | 5b, 5d |

## What the probes taught us (things the design must respect)

1. **AISStream does not cover the Middle East.** In a 90 s global sample
   (4,555 position reports) there were zero reports near Hormuz,
   Bab-el-Mandeb, Suez, the Taiwan Strait and the Bosporus; Malacca (48
   ships), Gibraltar (23), the Cape (16), Dover (12) and Panama (2) were
   covered. Coverage comes from volunteer land receivers. **No ships in
   AISStream does not mean no traffic.** The UI must show coverage, not just
   ships.
2. **Live status of Hormuz is NEAR-LIVE (about 12 days old), not LIVE.** The
   only free physical traffic signal there is PortWatch (satellite AIS,
   weekly updates). Faster signals at Hormuz are media (GDELT, 15 min),
   prices (Brent, daily) and sanctions (daily).
3. **The data already contains a major Hormuz disruption.** PortWatch
   monthly mean transits per day: 2025 between 55 and 103; **March 2026 3.2,
   April 7.1, May 3.9, June 12.9, July 10.2, Aug 4.7, Sep 3.6, Oct 3.5**.
   Brent is at 107 USD. We have not yet established the cause. AIS-based
   counts also fall when ships switch transponders off ("go dark") or when
   GPS is jammed, so part of the drop may be measurement, not traffic. The
   model must treat this as a known confounder.
4. **Sources go down, temporarily.** PortWatch's chokepoint layer returned
   HTTP 400 (including IMF's own download) for about 15 minutes, then recovered. NGA MSI
   is down for maintenance. The system must keep the last good data and mark
   it stale, never show zero.
5. **Comtrade's mode of transport is recorded at the reporter's border.**
   Swiss imports from China show as road/rail/air, and US rows carry only
   the total mode (`motCode` 0). The sea leg is invisible in Comtrade for
   many flows, so it has to be modelled, with US Census port data as the check.
6. **China has stopped appearing in Comtrade monthly data after 2024-12.**
   China↔X flows must come from partner (mirror) reports, which brings in
   the usual CIF/FOB and timing mismatches.
7. **MARNET tags Suez, Panama, Malacca, Bab-el-Mandeb, Gibraltar, Dover and
   others, but not Hormuz.** We tag every lane segment the same way, by
   distance to PortWatch's 28 chokepoint coordinates, so tagging is uniform.
8. **GDELT's DOC API rate-limits to one request per 5 s and reset our
   connections.** We use the raw 15-minute event files instead.
9. **OpenSanctions' full dataset is about 4 GB.** The `maritime` subset is 5 MB and
   carries IMO numbers, which join directly to AIS `ShipStaticData.ImoNumber`.

## Not used, and why

| candidate | reason |
|---|---|
| Baltic Dry Index, container freight indices | no free official API; FRED deep-sea freight PPI used as a labelled proxy |
| Global Fishing Watch | first judged redundant with PortWatch; **worth revisiting** because AISStream has no Gulf coverage and GFW's satellite data may be fresher than PortWatch's weekly update |
| Panama Canal Authority | no machine-readable Gatún Lake / draft feed found (WordPress JSON only exposes news posts); Panama transits come from PortWatch |
| ACLED | restrictive licence; GDELT + UCDP cover conflict signal |
| EIA, ECB, IMF commodity prices | covered by FRED |
| Eurostat Comext, Korea 20-day exports | subset of what Comtrade covers; low marginal value |
| company / deal events | no free source; proxies only (GDELT economic themes) |

## Action needed

- **Census key:** api.census.gov rejects the key (`invalid_key.html`). Census
  keys must be activated via the link in the confirmation e-mail.
