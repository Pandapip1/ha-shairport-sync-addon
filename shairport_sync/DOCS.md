# Home Assistant App: Shairport Sync

Turns an audio output on this device (e.g. its 3.5mm jack) into an AirPlay
speaker that iPhones, iPads and Macs can stream to directly.

## What this is (and isn't)

- This makes the speaker discoverable and playable **directly from Apple
  devices**, the same way a HomePod or AirPort Express would be. It bypasses
  Home Assistant entirely for that playback path - there is no
  `media_player` entity created by this app, because there's no official
  Home Assistant integration for controlling a Shairport Sync receiver.
  If you also want a `media_player` entity for TTS/automations on the same
  speaker, install the VLC or MPD app alongside this one - all three can
  share the same PulseAudio sink at once.
- **As of 2.0.0, this is full AirPlay 2**, not just classic AirPlay. Alpine's
  packaged `shairport-sync` (what 1.0.0 used) isn't built with
  `--with-airplay-2`, so this app now builds `shairport-sync` itself via Nix
  (pinned to a specific nixpkgs commit) with that flag enabled, plus the
  separate [NQPTP](https://github.com/mikebrady/nqptp) companion daemon
  AirPlay 2 needs for clock timing/sync - also built via Nix, running as its
  own service that starts before shairport-sync.
- **The real cost of that:** this override combination (AirPlay 2 on, most
  other backends off) almost certainly isn't sitting in nixpkgs' public
  binary cache, so Supervisor building this app locally means compiling
  ffmpeg, openssl, shairport-sync and nqptp from source on your own device.
  That's slow and disk-heavy, and plausibly painful on something like a
  Raspberry Pi. If you're installing this on more than one device, build it
  once via CI and publish the image instead - see the top-level README.
- **As of 3.0.0, the entire image is built by Nix, not just
  shairport-sync/nqptp.** `avahi`, `dbus`, and process supervision (plain
  `s6`, specifically `s6-svscan` as PID 1 - not the heavier `s6-overlay`/
  `s6-rc`/`bashio` stack the 1.0.0/2.0.0 builds used, and not Alpine's `apk`
  packages either) are all defined in this app's `nix/default.nix` and built
  from source the same way shairport-sync/nqptp already were. The final
  image has **no Alpine underneath it at all** (`FROM scratch` in the
  Dockerfile) - it's only what Nix built, plus that build's own runtime
  closure.
- **This has actually been built and run**, not just written and read. A
  real Nix + Docker toolchain was installed and used to build the real
  Dockerfile end to end (with only two sandbox-specific substitutions:
  nixpkgs came from a local git clone instead of a raw GitHub archive
  download, which this sandbox's network policy blocks, and the Nix
  builder was pointed at the sandbox's own TLS-intercepting proxy CA -
  neither applies on a real device with ordinary internet access), then run
  as a real container against a real PulseAudio server. That process found
  and fixed six real bugs that a read-only review had missed - see
  `CHANGELOG.md`'s 3.0.0 entry for the list. Only two things remain
  genuinely untested; see "What hasn't been tested" below.
- **The actual measured build cost turned out to be much smaller than
  originally expected.** Only `shairport-sync` itself (about 30 seconds)
  and the four small hand-written config files are compiled from source;
  `avahi`, `dbus`, `s6`, `nqptp`, `jq`, `gnused`, and shairport-sync's own
  `ffmpeg`/`openssl`/`soxr`/etc. build inputs all came straight from
  `cache.nixos.org` as prebuilt binaries in the sandbox's own test build,
  because none of those packages carry any override that would change
  their derivation hash. The full end-to-end `docker build` (from a cold
  Nix store) took under a minute, and the runtime closure copied into the
  final image was 145 store paths / about 350 MB total. Your own build
  time will vary with network speed and CPU, and a nixpkgs commit bump
  could of course change what's cached, but "compiles ffmpeg from source"
  - an earlier, unverified guess in this file - was wrong.

## Installation

1. In Home Assistant, go to **Settings** > **Apps** > **Add-on Store**,
   add this repository, then find and install "Shairport Sync".
2. There is no prebuilt image published for this app - Supervisor builds it
   locally from the Dockerfile in this repo the first time you install it.
   As measured in the sandbox this was developed in (see above), most of
   what gets built comes straight from `cache.nixos.org` as prebuilt
   binaries, and only `shairport-sync` itself compiles from source (about
   30 seconds on that machine) - so this should be noticeably lighter than
   the "expect a full from-source build" warning in earlier versions of
   this file, though a slower CPU, a slower connection to the binary cache,
   or a nixpkgs commit bump that invalidates the cache could all still make
   a real install slower than that. Updates after that only rebuild if you
   bump `NIXPKGS_REV` in the Dockerfile.
3. Set your preferred `airplay_name` (and optionally a `password`) in the
   app's Configuration tab, then start it.
4. On your iPhone/Mac, open Control Center's AirPlay picker (or the
   AirPlay icon in Music/Apple Music/any app) - your speaker should appear
   under the name you set, and should now support AirPlay 2 features like
   being added to a multi-speaker group in the Home app.

## Configuration

```yaml
airplay_name: "Home Assistant"
password: ""
interpolation: "soxr"
```

### Option: `airplay_name`

The name this speaker advertises. Shown in the AirPlay device picker on
Apple devices.

### Option: `password`

Optional. If set, Apple devices will be prompted for this password before
they can connect. Leave blank (the default) to allow anyone on your LAN to
connect without a password. This only applies to AirPlay 1 connections.

### Option: `interpolation`

Either `soxr` (better quality, more CPU) or `basic` (cheaper). Use `basic`
if you're running this on something underpowered and hear audio glitches.

## Why `host_network` and `realtime` are enabled

AirPlay discovery works over mDNS/Bonjour, which relies on LAN multicast.
Docker's normal bridge networking does not pass multicast traffic through,
so this app has to bind directly to the host's network (`host_network:
true`) for phones to find it at all. `realtime: true` gives the app
real-time scheduling access, which shairport-sync uses to keep audio
buffering jitter-free - without it you may hear occasional clicks/pops.

## Troubleshooting

- **Speaker doesn't show up in AirPlay picker**: check the app's log for
  Avahi errors, and confirm your phone/Mac is on the *same* LAN/VLAN as
  your Home Assistant host - mDNS does not cross subnets or most VLANs
  without an mDNS reflector.
- **Install fails or times out while building**: check the log for which
  package was building (most packages should come from the binary cache
  per the measurements above - a package compiling from source that isn't
  `shairport-sync` itself may mean the binary cache was unreachable, or
  that a `NIXPKGS_REV` bump changed what's cached) and whether it's a
  disk-space or timeout issue. Consider building via CI instead (see the
  README) rather than on-device.
- **nqptp fails to bind ports 319/320**: something else on the host is
  already using them (rare, but possible if you're running another PTP-ish
  service). nqptp needs *exclusive* access to both.
- **AirPlay works but multi-room/"Add to Home" features don't**: per
  upstream's own AirPlay 2 docs, "Multiple instances of the AirPlay 2
  version of Shairport Sync can not be hosted on the same system" - if
  you've somehow got two copies running (e.g. this app plus a manual
  install), stop one of them.
- **No sound / "waiting for PulseAudio socket"**: the Supervisor's audio
  container (`hassio_audio`) may not be running - check **Settings** >
  **System** > **Hardware**, or run `ha audio info` from the Home
  Assistant CLI/SSH add-on.
- **Wrong output device**: this app plays to whatever PulseAudio considers
  the default sink. If your host has more than one audio output (e.g. HDMI
  *and* the 3.5mm jack), set the correct default with `ha audio` (see the
  Home Assistant `plugin-audio` docs). Unlike some other PulseAudio-backed
  apps, there is no per-app `sink = "..."` override available here - this
  build's `pulseaudio` output backend takes no settings at all (confirmed
  by `shairport-sync -h`), so it always plays to PulseAudio's current
  default sink.

## Harmless log messages

A few lines observed in real logs during testing look alarming but aren't
fatal - the daemons print them and keep running:

- `dbus-daemon[N]: [system] org.freedesktop.DBus.Error.AccessDenied: Failed
  to set fd limit to 65536: Operation not permitted` - dbus tries to raise
  its own file-descriptor limit and can't in an unprivileged container;
  it carries on with whatever limit it already has.
- `avahi-daemon: WARNING: No NSS support for mDNS detected, consider
  installing nss-mdns!` and `Failed to read /etc/avahi/services.` - this
  image doesn't ship `nss-mdns` (only needed for *resolving* other
  hosts' `.local` names from inside the container, not for *advertising*
  this speaker) or a static `/etc/avahi/services/` directory (not needed
  since shairport-sync registers its own AirPlay service dynamically).

## What has and hasn't been tested

This app was built and run for real: a Nix toolchain and Docker were
installed in the development sandbox, the actual `Dockerfile` was built
end-to-end into a real `FROM scratch` image, and that image was run as a
real container against a real (locally-run) PulseAudio server. Confirmed
working, by actually observing it happen:

- `dbus`, `avahi`, `nqptp`, and `shairport-sync` all start, in order, under
  `s6-svscan` as PID 1, and stay up (verified via `docker top` showing all
  five processes alive together, supervised).
- `avahi-daemon` completes real mDNS registration and join its multicast
  groups.
- `shairport-sync` reads `airplay_name`/`interpolation`/`password` from a
  test `/data/options.json` via `jq`, renders `/etc/shairport-sync.conf`,
  connects to a real PulseAudio server over its Unix socket, and ends up
  listening on TCP port 7000 (AirPlay 2's RTSP port - confirmed with a
  direct TCP connection from outside the container).

That process is what found and fixed the real bugs listed in
`CHANGELOG.md`'s 3.0.0 entry (a heredoc-quoting bug that broke the Nix
build outright, `s6-svscan` needing an explicit scan-directory argument,
missing `/etc/passwd`/`/etc/group`/`/etc/nsswitch.conf` for glibc's NSS,
avahi-daemon's actual (different-than-assumed) command-line flags, a
missing `/tmp` and `$PULSE_SERVER` for libpulse, and the audio backend's
real name being `"pulseaudio"` rather than `"pa"`) - none of which a
read-only review had caught.

The same image was then also built and run with **podman** instead of
Docker (Supervisor itself uses Docker, not podman, but this is the closest
container-runtime cross-check available without a real HAOS device), this
time approximating the actual app options this app declares in
`config.yaml`: `--network host` (for `host_network: true`) and `--cap-add
SYS_NICE` (for `realtime: true`), against a real PulseAudio server. Two
things came out of that specifically worth knowing:

- Podman needed `unqualified-search-registries` configured
  (`/etc/containers/registries.conf`) and the build run with `--network
  host` for its own outbound access, neither of which is a property of
  this app - both are sandbox/podman-setup specifics, not something a
  real HAOS Supervisor install needs to worry about.
- With real `--network host`, avahi bound to the *actual* host network
  interfaces (not a container bridge) and `nqptp` was confirmed - directly
  on the host, via `ss -uln` - bound to the real UDP ports 319 and 320,
  and shairport-sync confirmed listening on the real host's TCP port 7000.
  This is the closest this testing got to how the app actually behaves
  under Supervisor's `host_network: true` + `realtime: true` combination.

Two things remain genuinely untested, because they need either a real HA
Supervisor environment or a real AirPlay client, neither of which existed
in the sandbox this was built in:

- **Graceful shutdown under Supervisor.** The container-internal behavior
  (s6-svscan supervising and restarting its children) was observed
  directly, but how it responds to Supervisor's actual stop/restart
  sequence (as opposed to a plain `docker stop` from this sandbox, which
  was not separately timed) hasn't been.
- **An actual AirPlay 2 connection from a real Apple device**, including
  multi-room/"Add to Home app" pairing - the sandbox confirmed the RTSP
  port is open and the daemon is alive, but had no iPhone/Mac/HomeKit
  environment to actually stream to it from.

If you hit a problem with either of these, please open an issue.

## Support

This is a personal/community app, not an official Home Assistant app.
Open an issue on this repository's GitHub if something's broken.
