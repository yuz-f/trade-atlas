# FIXTURES — test data only

Real responses captured by `atlas probe` (2026-11-06). They exist so that
parser tests run against what the sources actually send. The running system
never serves these as live data. API keys are never stored here (URLs in
`PROBE.md` show `<REDACTED>`).

Refresh with `zig build run -- probe [id]`, then `zig build test`.
