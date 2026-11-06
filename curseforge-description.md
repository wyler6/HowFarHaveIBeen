# How Far Have I Been

**Ever wondered how far you've actually run across Azeroth?**

How Far Have I Been keeps a running tally of every step your character takes, and marks each milestone with the level-up fanfare and a shout-out to your guild.

Made for **WoW Forever**.

---

## Features

### Every step counts
- Tracks your distance **on foot**, split into **walked** and **ran**
- Keeps separate totals for **swimming**, **riding**, and running back **as a ghost**
- Shows totals for each character, for **this session**, and for **all your characters combined**
- Displays distance in miles, kilometres or yards

### Only *your* travel
- Flight paths, boats and zeppelins don't count
- Teleports, hearthstones, blinks and loading screens don't count
- Running into a wall doesn't count, because distance comes from where you actually moved

### Milestones
- Every **5 miles** on foot, you hear the **level-up sound**. You can set any distance, in miles or kilometres.
- Your guild sees a message like:
  `Firstname Surname has travelled 10 miles on foot!`
- Uses your **full Forever name**, first name and surname
- Never interrupts a fight: guild messages wait until combat is over
- Try it privately first with `/howfar milestone test`

### Stays out of your way
- A small panel you can drag anywhere, lock in place, or hide
- Hover over it for the full breakdown; right-click it for options
- Lightweight, with no libraries. Your totals are saved on your computer only.

---

## Getting started

1. Install the addon and log in. The panel appears near the top of your screen.
2. Go for a run.
3. Hover over the panel to see your totals, and right-click it to open the options.

---

## Options

Open the options window by right-clicking the panel, typing `/howfar options`, or going to **Esc > Options > AddOns > How Far Have I Been**.

- **Display:** show or lock the panel, choose units, reset the panel's position
- **Milestones:** turn them on or off, choose how often, guild message, sound, and a test button
- **Data:** reset this character's totals (asks first)

---

## Commands

Type `/howfar` or `/hfib`:

- `/howfar`: a summary of your totals
- `/howfar options`: open the options window
- `/howfar show`, `hide`, `lock`, `unlock`: control the panel
- `/howfar units miles`, `km` or `yards`: change units
- `/howfar milestone 10`: a milestone every 10 miles (add `km` for kilometres)
- `/howfar milestone off`: turn milestones off
- `/howfar milestone test`: preview the sound and message (never posts to guild)
- `/howfar announce on` or `off`: the guild message
- `/howfar sound on` or `off`: the milestone sound
- `/howfar reset confirm`: erase this character's totals
- `/howfar help`: list every command

---

## How it measures

Several times a second, the addon checks where you are and adds up the real distance you've moved. Inside dungeons and raids, where the game hides your position, it estimates distance from your movement speed instead.

---

## FAQ

**Will it spam my guild?**
No. At normal running speed a mile takes a little over 4 minutes, so the default of every 5 miles means at least 20 minutes of non-stop running between messages. You can make it less frequent, or turn guild messages off and keep just the sound.

**Does riding count?**
Yes. Riding is tracked as its own total, but only distance on foot counts toward milestones.

**Does it work in dungeons?**
Yes. Inside instances it estimates distance from your speed.

**Will it know how far I went before installing it?**
No. Tracking starts the moment you install it.

**Does it work on Retail or Classic?**
No. It's built for WoW Forever only.

---

## Feedback

Found a bug or have an idea? Open an issue on [GitHub](https://github.com/wyler6/HowFarHaveIBeen/issues).
