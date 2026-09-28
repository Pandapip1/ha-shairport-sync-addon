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
  `CHANGELOG.md`'s 3.0.0 entry for the list. It has **since also been
  installed, built, started and stopped on a real Home Assistant OS 18.3
  Supervisor through the Supervisor API**, which found a seventh bug that
  made the app invisible in the Add-on Store entirely; see "Tested on a
  real Home Assistant Supervisor" and "What still hasn't been tested"
  below.
- **The image is deliberately trimmed, and that trimming needs this
  project's binary cache.** As built, the runtime closure is **75 store
  paths / 178 MB**, giving a **259 MB** image - down from 145 paths /
  343 MB / 504 MB before the trimming, all measured with `nix path-info
  -S` and `docker images` rather than estimated. What was removed, and how,
  is documented at the top of `nix/default.nix`; the short version is that
  shairport-sync's `ffmpeg` dependency was dragging in video encoders
  (x265, libaom, libvpx, svt-av1), `v4l-utils`, ALSA, Vulkan/VAAPI and a
  subtitle/text-rendering stack that an audio-only AirPlay receiver can
  never reach, `dbus` was pulling `systemd-minimal`, and `pkgs.bash` is
  `bash-interactive` (readline + ncurses) in an image whose only scripts
  are non-interactive.
- **The cost of that:** overriding ffmpeg's features changes its
  derivation hash, so the result is *not* in `cache.nixos.org` (verified
  by querying it directly). Without a substituter that has it, every
  install compiles ffmpeg from source **and runs its test suite**. The
  Dockerfile therefore adds this project's own binary cache as an extra
  substituter, alongside (not instead of) `cache.nixos.org`, with
  `fallback = true` so an unreachable cache degrades to a slow build
  rather than a failed install. With the cache reachable the whole closure
  is a ~37 MB download; `shairport-sync` itself still compiles, since it
  carries this app's own override combination.

## Installation

1. In Home Assistant, go to **Settings** > **Apps** > **Add-on Store**,
   add this repository, then find and install "Shairport Sync".
2. There is no prebuilt image published for this app - Supervisor builds it
   locally from the Dockerfile in this repo the first time you install it.
   Most of the closure comes prebuilt from `cache.nixos.org`, plus this
   project's own cache for the trimmed ffmpeg (see above); `shairport-sync`
   itself always compiles, since it carries this app's own override
   combination. On a real HAOS 18.3 aarch64 Supervisor the build took
   between about 6 and 12 minutes depending on cache locality and how
   contended the machine was. Expect it to be slower on a Raspberry Pi,
   and much slower if this project's cache is unreachable, since ffmpeg
   then compiles from source and runs its test suite. Make sure you have a
   few GB of transient free space for the build cache, not just 259 MB for
   the image. Updates after that only rebuild if you bump `NIXPKGS_REV` in
   the Dockerfile.
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

### Tested on a real Home Assistant Supervisor

Since then this app has been installed and run on a **real Home Assistant
OS 18.3 Supervisor** (`haos_generic-aarch64`, booted under QEMU/KVM on an
aarch64 host, Supervisor 2026.09.2, Core 2026.9.4, machine `qemuarm-64`),
driven through the actual Supervisor API rather than by hand. Confirmed
there, by observing it happen:

- **The repository adds and the app builds and installs.** Supervisor ran
  its own `docker buildx build --platform linux/arm64` against this
  `Dockerfile` and reported `successfully installed`. Measured twice: the
  pre-trimming image took 5m41s to build and came out at 504 MB; the
  trimmed one (see above) came out at **259 MB**. Both installed and ran.
- **`cache.nixos.org` is reachable from inside Supervisor's build
  container** - the Nix build pulled prebuilt binaries normally, so no
  proxy or egress special-casing is needed.
- **`host_network: true` really does give this app the host's ports.**
  Checked with `ss` on the HAOS host itself, not inside the container:
  `nqptp` held real UDP 319 and 320, and `shairport-sync` was listening on
  real TCP 7000.
- **Avahi registered on the real host interfaces** (the HAOS host's
  physical NIC plus its `hassio`/`docker0` bridges), reaching `Server
  startup complete`, rather than on a container-private bridge.
- **The options plumbing works end to end** - `shairport-sync` logged
  `starting (AirPlay name: Home Assistant)`, i.e. it read Supervisor's
  real `/data/options.json` through `jq` and rendered its own config.
- **Graceful shutdown under Supervisor is fast.** Stopping the app through
  Supervisor's own lifecycle took **269 ms** end to end (its log going
  from `Stopping app_...` to `Cleaning app_...`), and **220 ms** on a
  second run with the trimmed image, because `s6-svscan` as PID 1 acts on
  `SIGTERM` promptly. This was previously the main untested risk here,
  since a large `timeout` would only ever delay a `SIGKILL` - hence
  `timeout: 30` in `config.yaml` rather than something inflated.

That process also found a real bug that no amount of local container
testing could have caught: `config.yaml` had `timeout: 1800`, but
Supervisor's schema caps `timeout` at **300**, so it rejected the entire
config file and **the app never appeared in the Add-on Store at all** -
while the repository itself loaded with no visible error. The only sign
was a single Supervisor log line (`Can't read .../config.yaml: value must
be at most 300 ... Got 1800`). See `CHANGELOG.md`.

**Size the disk for the build, not for the image.** The image is 259 MB,
but installing it moved the HAOS data partition by several GB. Broken
down on the real device with `docker system df`, the bulk of that is
**BuildKit's build cache** (3.7 GB after these builds, 2.7 GB of it
reclaimable), because the Dockerfile's builder stage necessarily holds the
full *build-time* Nix closure - every dependency's build inputs - not the
178 MB runtime closure that actually ships. Supervisor does prune build
cache (its `docker/manager.py` calls `prune_builds()`, logging "Prune
stale builds"), so this is not a permanent leak, but it is transient
headroom you need at install time. `docker buildx prune` reclaims it
immediately if you have host access. For context, HA Core's own image on
the same machine is 3.39 GB, so the add-on is not the dominant consumer
either way.

When the binary cache is reachable the build-time closure is largely
skipped, since Nix substitutes the finished `containerRoot` and its
runtime closure directly instead of realising the build dependencies -
in testing that install fetched 69 NARs (~37 MB) and never built ffmpeg.

### What still hasn't been tested

- **An actual AirPlay 2 connection from a real Apple device**, including
  multi-room/"Add to Home app" pairing. The RTSP port is confirmed open on
  the real host and the daemon confirmed alive and advertising, but there
  was no iPhone/Mac/HomeKit environment to stream from. Note also that the
  Supervisor test above ran under QEMU user-mode networking, which does
  not carry LAN multicast, so real-client mDNS discovery specifically was
  not exercised even though Avahi's own registration was.
- **Real audio actually coming out of a speaker.** The PulseAudio path was
  verified against a real PulseAudio server during container testing, but
  the Supervisor test host had no physical audio output to play to.

If you hit a problem with either of these, please open an issue.

## Support

This is a personal/community app, not an official Home Assistant app.
Open an issue on this repository's GitHub if something's broken.
