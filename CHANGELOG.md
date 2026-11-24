# Changelog

All notable changes to this project will be documented in this file.

## [1.0.7] - 2026-11-24

### Changed
- Picks up game-common 1.20.0: a deferred action (timer tick, computer's
  move, card flip) no longer runs once the game is closed or a new game has
  started, and the game is saved a few seconds after a move instead of after
  every one, and at once on close, suspend or power-off.

## [1.0.6] - 2026-11-24

### Changed
- Picks up game-common 1.19.0: with the Dashboard installed, the title bar's
  close icon becomes a house that goes back to it.

## [1.0.5] - 2026-11-24

### Changed
- Picks up game-common 1.18.0: a status line cut off with "…" opens in full
  when tapped, so a long hint can be read.

## [1.0.4] - 2026-11-18

### Changed
- Picks up game-common 1.17.0 (a board redraw fix used by chess, binairo and
  tatami; no change in this game).

## [1.0.3] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.0.2] - 2026-11-04

### Fixed
- The tool no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.0.1] - 2026-11-04

### Changed
- Uses less memory: the tool loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unused.

## [1.0.0] - 2026-11-03

### Added
- Stopwatch with laps: lap time and total for each lap, fastest and slowest
  marked, tenths shown once paused, full lap list in the menu.
- Countdown timers: one-tap presets (1, 3, 5, 10, 15, 30 min) and custom
  durations with a name; up to 8 running at once; pause, restart, rename,
  delete.
- Interval timer: work / rest × rounds with a "get ready" countdown.
- Alerts for a reader with no speaker: full-screen black/white flashes,
  frontlight blink, then a message to tap away.
- Timers keep running (and ring) after the screen is closed, while reading;
  the reader is kept awake while one runs; after a sleep, a message says what
  finished and when.
