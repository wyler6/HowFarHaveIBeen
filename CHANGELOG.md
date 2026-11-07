# Changelog

## Unreleased

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
