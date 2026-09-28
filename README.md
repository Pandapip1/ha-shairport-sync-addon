# Home Assistant Add-on Repository: Shairport Sync

Turns an audio output on your Home Assistant host (e.g. its 3.5mm jack) into
an **AirPlay 2** speaker. `shairport-sync` and its `nqptp` timing companion
are built via a pinned Nix expression (not Alpine's package, which lacks
`--with-airplay-2`), outputting to the Supervisor's PulseAudio container.

## Add this repository

In Home Assistant: **Settings** > **Apps** > **Add-on Store** > (⋮ menu) >
**Repositories**, then add:

```
https://github.com/gavinnjohn/ha-shairport-sync-addon
```

Then install "Shairport Sync" from the store. **Read
[`shairport_sync/DOCS.md`](shairport_sync/DOCS.md) first** - as of 2.0.0
this app compiles ffmpeg and shairport-sync from source via Nix on first
install, which is slow and disk-heavy on-device (see "Building via CI"
below for the alternative).

## Why this exists

Built after evaluating the two existing community Shairport Sync apps and
finding both unusable: one (`v3rm0n/addon-shairport-sync`) ships a prebuilt
image last updated ~2020 predating AirPlay 2 entirely, and its Dockerfile's
pinned base image tag no longer resolves; the other
(`XGFan/shairport-sync-ha`) is ARM-only and pulls its image from a personal,
non-standard Docker registry.

- **1.0.0** built locally from the current official
  `ghcr.io/home-assistant/{arch}-base:3.24` image plus Alpine's maintained
  `shairport-sync` package - patchable via ordinary `apk` updates, but
  classic AirPlay (AirPlay 1) only, since Alpine's build lacks
  `--with-airplay-2`.
- **2.0.0** switches to building `shairport-sync` (with `--with-airplay-2`)
  and its `nqptp` companion via a pinned Nix expression, since no Linux
  distro packages an AirPlay-2-capable binary. This gets real AirPlay 2
  support, at the cost of a much heavier on-device build - see
  `shairport_sync/DOCS.md` and the Dockerfile's own comments for the full
  reasoning (including why this deliberately avoids `pkgsStatic`/musl).
  The final image was still Alpine, with shairport-sync/nqptp's Nix store
  closure copied in - `avahi`/`dbus`/process supervision stayed on Alpine's
  `apk` packages and `s6-overlay`/`bashio`.
- **3.0.0** goes further: the *entire* image is now built by Nix -
  `avahi`, `dbus`, and process supervision (plain `s6`, not `s6-overlay`)
  too, not just shairport-sync/nqptp. The final image is `FROM scratch`;
  there's no Alpine underneath it at all. This is a deliberate tradeoff the
  Dockerfile itself becomes a thin, mostly Nix-generated artifact (it just
  builds one Nix derivation and copies its output in), with the real logic
  living in `shairport_sync/nix/default.nix` instead. This version was
  actually built and run end-to-end (a real Nix + Docker toolchain, a real
  PulseAudio server) rather than only read - see
  `shairport_sync/CHANGELOG.md` for the six real bugs that process found
  and fixed, and `shairport_sync/DOCS.md`'s "What has and hasn't been
  tested" section for the two things that remain open (they need a real
  Supervisor environment and a real Apple device, neither available in the
  sandbox this was built in).

## Building via CI instead of on-device

Compiling ffmpeg on a Raspberry Pi on every fresh install is not a good
experience. If you're installing this on more than one device, build the
image once instead:

1. Add a GitHub Actions workflow that runs `docker buildx build` for this
   app's `Dockerfile` (both `amd64` and `aarch64`, via QEMU or native
   runners) and pushes to `ghcr.io/<you>/shairport-sync-{arch}`.
2. Add `image: ghcr.io/<you>/{arch}-shairport-sync` to
   `shairport_sync/config.yaml`.
3. Supervisor will then pull your prebuilt image instead of rebuilding from
   the Dockerfile on every device.

This isn't set up in this repo yet - it's the natural next step if
on-device build time becomes a real problem for you.

## Requirements

- Home Assistant OS or Supervised (this depends on Supervisor's `audio` and
  `host_network` app options - it will not work on Home Assistant
  Container/Core-only installs).
- `aarch64` or `amd64` hardware.
- Enough free disk space and time for an on-device Nix build the first time
  you install (see above) unless you set up your own CI build.
