//! FIXTURES: real responses captured by `atlas probe` on 2026-11-06.
//! Used only by tests. Never served as live data.

pub const usgs = @embedFile("usgs/sample.json");
pub const gdacs = @embedFile("gdacs/sample.json");
pub const portwatch_ports_daily = @embedFile("portwatch_ports_daily/sample.json");
pub const portwatch_chokepoints_daily = @embedFile("portwatch_chokepoints_daily/sample.json");
pub const portwatch_chokepoints_db = @embedFile("portwatch_chokepoints_db/sample.json");
pub const portwatch_disruptions = @embedFile("portwatch_disruptions/sample.json");
pub const portwatch_tradenow = @embedFile("portwatch_tradenow/sample.json");
pub const fred = @embedFile("fred/sample.json");
pub const comtrade = @embedFile("comtrade/sample.json");
pub const gdelt_lastupdate = @embedFile("gdelt_events/lastupdate.txt");
pub const gdelt_export = @embedFile("gdelt_events/export_excerpt.tsv");
pub const aisstream = @embedFile("aisstream/messages.jsonl");
pub const opensanctions_index = @embedFile("opensanctions_maritime/index.json");
pub const opensanctions_head = @embedFile("opensanctions_maritime/maritime_head.csv");
