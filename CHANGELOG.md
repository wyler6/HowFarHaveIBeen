# Changelog

## 1.5.1

- **Report lines arrive in order.** Guild chat is now sent one message at a time, 0.25 s apart, so the lines
  of a distance report no longer arrive scrambled.
- **Fixed milestone guild messages being blocked by the game** ("Interface action failed because of an
  AddOn"). Guild chat is now sent from a timer, as the Details addon does.
- `/howfar debug` shows the last action the game blocked.

## 1.5.0

- **Distance report.** Ctrl+click the panel (or type `/howfar report`) to post your distances to guild chat,
  each on its own line: your on-foot total, then ran/walked, swam, glided, rode and ghost distance, leaving out
  anything that is zero. There is a 10 second cooldown between reports.

## 1.4.0

- **Characters are keyed by name only, not realm.** The realm name is not stable on Forever (an update
  blanked it and split each character's totals in two). Existing entries are merged back into one at
  login, adding the distances together; nothing is lost and no milestones fire.

## 1.3.0

- **Current speed on the panel.** Your movement speed shows in the panel's bottom-right corner, as a
  percentage of normal run speed, yd/s, mph or km/h. Turn it on or off and pick the format in the Options
  window or with `/howfar speed on|off|percent|yards|mph|kmh`.

## 1.2.0

- **Skyborne glide total.** Gliding is now tracked as its own distance (shown as "Glided" for
  Skyborne characters) and no longer counts as running or toward milestones.

## 1.1.0

- **Progressive milestones.** New option (Options window or `/howfar milestone progressive`):
  milestones at 1-5, then 10, 20 ... 100, 200 ... in miles or km, instead of a fixed step.

## 1.0.1

- **Shorter guild announcement.** Milestone messages now end at "on foot!" without the
  "(How Far Have I Been)" suffix.
- **Added the MIT license** to the download.

## 1.0.0

First release.

- **Tracks how far each character has travelled on foot.** Walking and running are counted
  together as on-foot distance and also shown separately, saved per character.
- **Swimming, mounted and ghost distance are tracked on their own**, so they never get mixed
  into the on-foot total.
- **Ignores everything that is not you moving.** Flight paths, boats and zeppelins,
  teleports and loading screens add nothing to your totals.
- **Measures by real position**, and falls back to speed multiplied by time where position
  is hidden, such as inside instances.
- **A draggable panel with a detailed tooltip.** Hover for the full breakdown, including
  totals for this session and for all of your characters.
- **Milestones.** Every N miles or km on foot, the level-up sound plays and a guild
  announcement is posted using the character's full Forever name (first name and surname).
  Guild messages wait until combat or chat lockdown ends rather than being dropped.
- **An options window**, opened by right-clicking the panel, with `/howfar options`, or
  from Esc, Options, AddOns.
- **Slash commands `/howfar` and `/hfib`.**
- **Built for WoW Forever** (interface 16001).
