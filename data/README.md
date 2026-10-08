# Curated rare data

`curated_rares.json` holds rares RareNet researched by hand: one entry per rare,
facts only, each with the public pages that state them. Written in our own words;
nothing is copied from other databases.

Rules applied by `tools/gen_forever.py` before an entry ships in the addon:

- NPC id and zone: stated by at least two independent sources (different sites),
  or one source plus `"verified": "in-game"`.
- Coordinates: only from a source that states them for Forever, or from in-game checks.
- Drops: shipped as "reported" when one source states them, "confirmed" with two.
- Entries with `"conflicts"` are kept here for review but never shipped.

Entry fields: `npc`, `name`, `zone`, `level`, `rank`, `tame`, `coords` ([[x, y]] in
map percent), `drops` ([{item, name}]), `sources` ([{url, facts, checked}]),
`conflicts`, `verified`.

`forever_tips.json` holds a short tip per Forever rare (where to find it, how to
fight it), written by RareNet in its own words from the facts ForeverChanges
lists. `tools/gen_tactics.py` ships them in `RareNet/Tactics.lua` ahead of the
classic vmangos data (spells, flee and call-for-help health, summons, respawn).
