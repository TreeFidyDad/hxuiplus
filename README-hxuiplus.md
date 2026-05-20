# hxuiplus

A personal fork of [HXUI](https://github.com/tirem/HXUI) with quality-of-life
patches applied. Designed to be **run in place of HXUI**, with upstream pulled
in periodically and merged.

> Original HXUI by Team HXUI (Tirem, Shuu, colorglut, RheaCloud).
> Upstream version this fork is based on: `1.1.1-onimitch4`.

## Why a fork

Running patched HXUI directly drifts as upstream updates. A fork lets us:
- Apply local QoL patches in clearly-marked blocks
- Pull upstream changes with `git fetch upstream && git merge upstream/main`
- Cherry-pick or revert individual upstream commits
- See exactly what diverges from upstream

## Install

1. Drop the `hxuiplus` folder into your Ashita `addons/` directory.
2. **Unload HXUI first** (`/addon unload hxui`) -- running both will fight
   over the same on-screen elements.
3. `/addon load hxuiplus`.

Commands: `/hxuiplus`, `/hxp`, plus all the originals (`/hxui`, `/hui`, `/horizonui`).

## Patches applied

### `partylist.lua`
- **Cure-waste tick marks on HP bars.** Cure I (thin) and Cure II (thick)
  vertical ticks show where each tier would land the target's HP. Green =
  clean (no waste), amber = some waste (>=30 HP), red = mostly wasted
  (>=50%). Bounded by `BEGIN/END HUNTPARTNER CURE-WASTE PATCH` comments.
- **MP bar recolored** from green to blue (`#3a7fc4 -> #6ba8e0`) to match
  the huntpartner player bar.
- **TP bar recolored** from blue to amber/orange (`#d68a1e -> #f0b85a`,
  with `#b86b00` overflow) to match the huntpartner player bar.

## Sync with upstream

```sh
git remote add upstream https://github.com/tirem/HXUI.git   # one-time
git fetch upstream
git merge upstream/main
# Resolve conflicts; the patch blocks are tagged so they're easy to spot.
git push origin main
```

## License

Inherits HXUI's license. See `LICENSE`.
