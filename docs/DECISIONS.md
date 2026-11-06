# Design decisions (agreed with Ily, Oct–Nov 2026)

Short record so that anyone (including a future Claude session) can pick up
the project without the original conversation.

## Scope and principles
- Live, interactive 3D globe of maritime trade: ports = nodes, routes = edges.
- Everything that can reasonably be Zig is Zig: ingestion, storage, graph
  and clustering, prediction, server, renderer core (WASM). Non-Zig glue is
  kept minimal and listed below.
- Free data only, as live as each source allows; every input is labelled
  LIVE / NEAR-LIVE / LAGGED / STATIC in the UI with its age.
- No fabricated data. Fixtures exist only for tests and are marked.
- Predictions always carry uncertainty and stated assumptions.
- Runs locally (`zig build run -- serve`); API keys stay on the server side.

## Routes
- A route is **a country-pair flow (by goods category) allocated to ports and
  sent along real sea lanes** (Eurostat MARNET), not a great-circle arc.
  Route numbers are *estimates* and are labelled as such.
- Allocation is checked against observed chokepoint transits (PortWatch)
  and, for the US, against real port-level trade (Census).
- Disruption: chokepoint edges get a penalty or are removed when the
  disruption signal fires; paths are recomputed and flows reassigned
  live. Diverted routes are drawn differently and show the extra distance and days; the
  original route stays as a faint ghost.
- **Hormuz has no sea bypass.** A blockade strands volume; only pipelines
  (Saudi East-West to Yanbu, UAE ADCOP to Fujairah) give partial bypass
  capacity, from published figures, labelled STATIC.

## Disruption signal
Per chokepoint, separate evidence channels so each one's contribution is visible:
physical (PortWatch transits vs baseline; AISStream counts *where covered*),
official (NGA warnings/ASAM), political/media (GDELT, sanctions), hazards
(GDACS, USGS). Output is a probability with its evidence, never a binary fact.

## Prediction
- Phase 1 baseline: forecasts from history only (seasonal naive, ETS), with
  prediction intervals; rolling-origin backtest.
- Phase 2: disruption model, target = "transits fall > X % below baseline
  within h days" (PortWatch, daily since 2019, many events). Named events
  (Ever Given 2021, Panama 2023, Red Sea 2023–24, Baltimore 2024, and the
  2026 Hormuz collapse found in M0) are out-of-sample case studies.
- Each family's contribution is measured with nested models (baseline,
  then + financial, + political, + media, + physical).

## Clustering
Multi-layer weighted graph (trade + UNGA alignment + media tone), Leiden
community detection, clusters matched across time windows, with a resolution
sweep and consensus stability reported. How much weight each layer gets is varied in a sensitivity analysis.

## Stack
- Zig 0.17.1 (pinned in build.zig.zon).
- Own HTTPS client (`src/net/https.zig`): std.http.Client does not run TLS
  through an HTTP CONNECT proxy in 0.17.1.
- Own WebSocket client (`src/net/websocket.zig`), own zip reader
  (`src/util/zip.zig`).
- Renderer: Zig → wasm32-freestanding, drawing with WebGL2 through a thin JS
  shim. Server pushes updates with Server-Sent Events.

## Non-Zig glue (planned, to be kept small)
| piece | why it cannot be Zig |
|---|---|
| `index.html` | the browser needs a page to load |
| WebGL2 function table (~60 functions) | WASM has no direct access to browser APIs |
| input events → WASM | same |
| fetch / EventSource → copy bytes into WASM memory | WASM cannot open network connections in a browser |
| DOM detail panel text | DOM is only reachable from JS |
| font rasterisation to a texture | uses the browser's canvas text API |

## Known limitations (so far)
- Zig 0.17.1's threaded `Io` panics on connect timeouts ("TODO"), so
  deadlines must be enforced by cancelling the fetch task (to do in M1).
- MARNET ships as GeoPackage (SQLite); a minimal read-only SQLite page
  reader in Zig is planned for M1/M3 to avoid a C dependency.
