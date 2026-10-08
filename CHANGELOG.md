# RareNet changelog

## 0.8.0 (beta)
- New "How to fight it" tab in the rare database (`/rarenet db`): what each rare does and how to take it on, for more than 400 rares.
- Forever first: for Forever rares, a tip on where to find it and how to fight it (group or solo, respawn, kiting...), and its Forever rank (elite or not) in blue.
- Then the classic data, marked as such: the spells it casts (hover one for the game's own description), what it does below a given health (heals, enrages, bites harder), when it flees or calls for help, what it summons and how long it takes to respawn.
- Forever's name and level now win over the classic ones: the Alliance Outrunners show as such, level 24.

## 0.7.4 (beta)
- Heartrazor, the rare elite wyvern of Highperch in Thousand Needles (level 32), now has its Forever spawn points (three nests on the western cliffs) and its new Forever drop, the Wyvern Heart Band.

## 0.7.3 (beta)
- Clearer rare icons on the map and minimap: a skull on a dark disc with a coloured ring (white known spawn, gold tameable, blue new in Forever, purple found by RareNet players, green live on your layer, orange live on another layer).
- Click a rare on the map to keep its spawn points shown, even when the 3D preview would cover them. Click it again, or another rare, to change that. Right click now sets the waypoint (or hops layers for a live rare on another layer), shift-click still opens the details.
- A rare that is up right now sends out radar waves on the map and minimap, drawn above the known spawn points, so a reported rare stands out. Another layer is now a deeper orange, easier to tell from the gold of tameable rares, and the open map drops sightings as soon as they expire.
- New settings: opacity of the skull icons on the map and on the minimap (40% to 100%). Live rares and the rare you hover or select always stay at full opacity.
- The online count now matches `/rarenet members`: it counts everyone in the RareNet channel. `/rarenet peers` also lists who is in the channel but did not answer (in a dungeon, where RareNet stays quiet, on a version older than 0.3.2, or with RareNet turned off).
- Rare database: the details no longer run under the 3D model (long names get a smaller font, tags and text wrap), and the model shows on the first click instead of staying black. The map preview loads its model reliably too.
- Fixed: a rare seen by only one player could alert again and again every few minutes, then vanish from the list and the map in between. A rare on one layer now alerts once (and again when it respawns after a kill), old sightings passed on by other players no longer alert or flash onto the map, and a rare in view is announced often enough to stay on everyone's map.
- Alerts, the live list and map tooltips now say who reported the rare ("seen by Name"). Click the name in chat to whisper them.
- The new icons are new files: restart the game completely after updating (a /reload is not enough).

## 0.7.2 (beta)
- 21 undiscovered rares: rares that exist in Forever but nobody has located yet (Scaldaron, Varkharn the Vigilant, Old Ironfang, Kargra the Blind and more). Find them in the rare database with the new "Undiscovered" filter.
- Be the first to find one: RareNet recognises them, shows a "First discovery!" alert, and shares the location so they appear on every RareNet player's map.

## 0.7.1 (beta)
- The rare database got a makeover in the game's own style, and a search box (rare, zone or item name: type "helm" to find who drops one), a zone menu grouped by continent, and filters: tameable, new in Forever, with Forever loot, seen now, near your level, sorted by level, name or zone. Right click a rare in the list for a waypoint.
- Rare icons on the minimap: known spawn points nearby, and live sightings (green on your layer, orange on another) that stay on the edge of the minimap pointing the way when they are far. "Minimap icons: All / Live only / Off" in the settings.

## 0.7.0 (beta)
- 28 new Forever rares, with their spawn points and whether hunters can tame them: they are now detected, alerted, shown on the map and listed in the rare database. Classic rares also get their new Forever spawn points.
- The rare database shows each rare's known Forever drops (for example Foreman Rigger's Foreman's Helm), between what RareNet players have seen and the classic drop table.
- A cleaner map: one pin per rare instead of one per spawn point. Hover it and all of its spawn points light up. "Spawn points per rare: All points" in the settings brings back the old view.
- *Forever rare spawns and loot: ForeverChanges (foreverchanges.pro), used with their permission.*

## 0.6.0 (beta)
- RareNet now learns what rares really drop in Forever. When you loot a rare, its drops are recorded and shared with other RareNet players, so new Forever items (that no classic database has) show up in everyone's rare database with how often they dropped.
- The rare database shows "Seen by RareNet players" first, with drops per looted kill and how many players saw each item, and the classic drop table below in grey.
- Each corpse counts once, however many players loot it. Skinning, gathering and pick pocketing are not counted as kill loot, and quest items are left out.
- Map pin tooltips list the drops seen in Forever first.

## 0.5.0 (beta)
- New rare database (`/rarenet db`, or right click the minimap button): browse the rares of every zone, with a turning 3D preview, level, spawn points, live status and what each one drops, with drop chances.
- Item tooltips on hover; shift-click links an item in chat and ctrl-click tries it on, as anywhere else in the game.
- "Waypoint to spawn" and "Show on map" buttons for the selected rare (the map waits until you leave combat).
- Map pin tooltips now list the rare's top drops. Shift-click a pin, or a rare in the live list, to open it in the database. Left click still sets a waypoint and right click still hops layers.
- Right clicking the minimap button opens a menu: rare database, live list, settings and test alert.

## 0.4.0 (beta)
- New alerts: the rare's name in big letters at the top of the screen, with where it is, whether it is on your layer and whether it is tameable.
- RareNet's own alert sounds (sonar, chime and horn), plus the game's raid warning, ready check and alarm clock. Pick one in the settings, and play it on the Master or Effects channel.
- Waypoint to the rare when the alert goes off, so the arrow takes you there.
- New Alerts section in the settings: rares you find, rares others report, big text and its size, waypoint, sound, and a Test button. `/rarenet test` shows a test alert too.

## 0.3.5 (beta)
- Alerts for rares you find yourself: when RareNet spots a rare around you it now plays the alert and shows "<rare> nearby!" (once every 5 minutes per rare). It can be turned off in the settings ("Alert for rares you find").

## 0.3.4 (beta)
- `/rarenet members` showed the members of another public channel (up to 500 names). It now lists only the people in the RareNet channel.

## 0.3.3 (beta)
- New `/rarenet members` (or `/rarenet who`): lists everyone in the RareNet channel, whatever version they run, with their names as links. Click a name to whisper them.

## 0.3.2 (beta)
- New `/rarenet peers`: asks who is running RareNet right now and lists them with their version. In a big network only a sample answers, so it never floods the channel.

## 0.3.1 (beta)
- Works with Layer-Swap and Forever Layer Hop: right click a rare on another layer, in the list or on the map, and RareNet asks your layer addon to take you there (Layer-Swap goes straight to that layer when it knows it; Forever Layer Hop opens with the layer to pick). RareNet never changes your layer by itself.
- The question about enemy nameplates is now RareNet's own small window instead of a game popup, which could get other game dialogs blocked.
- RareNet no longer adds an entry to the game's settings panel; the minimap button and /rarenet config open its settings.
- /rarenet diag also shows any game action that was blocked because of RareNet.

## 0.3.0 (beta)
- First public release for World of Warcraft: Forever.
- Detects your layer from the creatures around you and tags every rare sighting with it.
- Rare sightings are shared live between RareNet players over a hidden addon channel (guild as a fallback).
- Players who log in catch up with the sightings they missed: one player answers, the rest only fill gaps.
- Sightings check themselves: they expire, witnesses refresh them, and players who walk past a reported spot without seeing the rare mark it doubtful.
- A report only counts as confirmed when two players saw it first hand. Players whose uncorroborated reports keep being refuted are muted for a while; honest players are never punished for a rare that was killed or wandered off.
- World map pins for known rare spawns, tameable rares, rares discovered by RareNet players, and live sightings coloured by layer. Hover a pin for a 3D preview of the rare, click it for a waypoint.
- Rare list window, minimap button, settings window and chat, sound and raid warning alerts.
