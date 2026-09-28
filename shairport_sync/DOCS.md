# Home Assistant App: Shairport Sync

Turns an audio output on this device (e.g. its 3.5mm jack) into an AirPlay 2
speaker that iPhones, iPads and Macs can stream to directly.

## What this is (and isn't)

- Playback goes **straight from the Apple device to this app**, the way it
  would to a HomePod or AirPort Express. Home Assistant is not in that path
  and no `media_player` entity is created, because there is no official
  integration for controlling a Shairport Sync receiver. If you want a
  `media_player` for TTS and automations on the same speaker, install the VLC
  or MPD app alongside this one - they can share the PulseAudio sink.
- This is **full AirPlay 2**, not classic AirPlay. Alpine's packaged
  `shairport-sync` is not built with `--with-airplay-2`, so this app builds it
  with Nix, along with the [NQPTP](https://github.com/mikebrady/nqptp)
  companion daemon that AirPlay 2 needs for clock sync.
- The **entire image is built by Nix and based on nothing**: `avahi`, `dbus`
  and process supervision (plain `s6-svscan` as PID 1, not `s6-overlay`/
  `s6-rc`/`bashio`) are all defined in `nix/default.nix`. The final image is
  `FROM scratch` - there is no Alpine underneath it.
- It is built against **musl**, and that is why it needs this project's binary
  cache: nothing in a musl build of this stack is in `cache.nixos.org`. With
  the cache reachable the whole closure is a **9.8 MiB download** and nothing
  compiles; without it, dbus, avahi, libpulseaudio, ffmpeg and shairport-sync
  all build from source. `fallback = true` means an unreachable cache is slow,
  not fatal.
- The result is small: a **37-path, 49.8 MB runtime closure** and a **53 MB
  image** (71.6 MB as Docker accounts for it on the device), down from 145
  paths / 343 MB / 504 MB before any trimming.

## Installation

1. In Home Assistant, go to **Settings** > **Apps** > **Add-on Store**, add
   this repository, then install "Shairport Sync".
2. There is no prebuilt image; Supervisor builds it locally the first time you
   install. With the binary cache reachable that took about two minutes on an
   aarch64 HAOS 18.3 Supervisor. Updates only rebuild when `NIXPKGS_REV`
   changes in the Dockerfile.
3. Size the disk for the *build*, not the image. The builder stage holds the
   build-time closure, and BuildKit's cache reached 7.2 GB across repeated
   builds here - far more than the ~70 MB that ships. Supervisor prunes it
   (`prune_builds()`), and `docker buildx prune` reclaims it immediately if
   you have host access. For scale, HA Core's own image is 3.39 GB.
4. Set `airplay_name` (and optionally `password`) in the Configuration tab and
   start it.
5. On your iPhone or Mac, open the AirPlay picker - the speaker should appear
   under the name you set, and support AirPlay 2 features like joining a
   multi-speaker group.

## Configuration

```yaml
airplay_name: "Home Assistant"
password: ""
interpolation: "soxr"
```

### Option: `airplay_name`

The name this speaker advertises in the AirPlay picker.

### Option: `password`

Optional. If set, Apple devices are prompted for it before connecting. Applies
to AirPlay 1 connections only.

### Option: `interpolation`

`soxr` (better quality, more CPU) or `basic` (cheaper). Use `basic` if you
hear glitches on underpowered hardware.

## Why `host_network` and `realtime` are enabled

AirPlay discovery is mDNS, which needs LAN multicast, and Docker's bridge
networking does not pass multicast through - so this app binds directly to the
host network or phones never find it. `realtime: true` gives shairport-sync
real-time scheduling, which keeps audio buffering jitter-free.

## Troubleshooting

- **Speaker doesn't appear in the AirPlay picker**: check the log for Avahi
  errors and confirm the phone is on the same LAN/VLAN - mDNS does not cross
  subnets without a reflector.
- **Install fails or times out**: check which package was building. Anything
  compiling from source means the binary cache was unreachable, or a
  `NIXPKGS_REV` bump changed what it holds.
- **nqptp fails to bind 319/320**: something else on the host holds them.
  nqptp needs exclusive access to both.
- **AirPlay works but multi-room doesn't**: upstream does not support two
  AirPlay 2 instances on one host. Stop any other copy.
- **No sound, or "waiting for PulseAudio socket"**: the Supervisor audio
  container may not be running - check `ha audio info`.
- **Wrong output device**: this app plays to PulseAudio's default sink. Set
  the right default with `ha audio`; this build's `pulseaudio` backend takes
  no per-app `sink` setting.
- **Connects but silent**: senders that negotiate uncompressed L16 rather than
  ALAC need the `pcm_s16be` decoder and the upstream L16 fix, both of which
  the pinned revision carries. If you repin to something older, shairport-sync
  feeds L16 to the ALAC decoder and every packet fails with
  `AVERROR_INVALIDDATA` - visible only with `-vv`. Note also that a sender
  which never sets a volume leaves shairport-sync at its initial -24 dB, which
  attenuates below the 16-bit LSB and is indistinguishable from silence.

## Harmless log messages

- `Failed to set fd limit to 65536: Operation not permitted` - dbus cannot
  raise its own file-descriptor limit in an unprivileged container and carries
  on with the existing one.
- `WARNING: No NSS support for mDNS detected, consider installing nss-mdns!`
  and `Failed to read /etc/avahi/services.` - `nss-mdns` is only needed to
  *resolve* other hosts' `.local` names, not to advertise this speaker, and
  shairport-sync registers its service dynamically rather than from a static
  services directory.

## What has been verified

Tested on a **real Home Assistant OS 18.3 Supervisor** (`generic-aarch64`
under QEMU/KVM, Supervisor 2026.09.2, Core 2026.9.4), driven through the
Supervisor API rather than the frontend:

- **Repository add, build, install, start, stop and uninstall** all work.
  Supervisor builds the image with its own `docker buildx build`.
- **Real audio plays.** A 440 Hz tone streamed from a real AirPlay sender came
  back off the PulseAudio sink monitor at 439 Hz and full scale, so the whole
  path - RTSP, RTP, decode by this image's trimmed ffmpeg, PulseAudio output -
  works end to end.
- **AirPlay 2 `GET /info` and HomeKit transient pair-setup** both complete,
  which exercises this build's openssl.
- **mDNS advertises correctly**: `_airplay._tcp` and `_raop._tcp` resolve with
  full TXT records on every interface.
- **`host_network: true` gives the app real host ports** - checked with `ss`
  on the HAOS host: nqptp on UDP 319/320, shairport-sync on TCP 7000.
- **Options plumbing works** - shairport-sync reads Supervisor's own
  `/data/options.json` through `jq` and renders its config.
- **Graceful shutdown takes 0.21 s** with exit code 0, because `s6-svscan` as
  PID 1 acts on `SIGTERM` promptly. Hence `timeout: 30` in `config.yaml`; a
  larger value would only ever delay a `SIGKILL`.

## What has not

- **A stream from a real Apple device.** AirPlay 2 audio is PTP-timed, and the
  only senders that speak it are Apple's own; the sender used here negotiates
  the AirPlay 1 fallback instead. Discovery from a real client was also not
  exercised, since QEMU user-mode networking does not carry LAN multicast.
- **Audio out of a physical speaker.** The test host has no audio hardware, so
  playback was measured at a PulseAudio null sink rather than heard.

Please open an issue if you hit a problem with either.

## Support

This is a personal/community app, not an official Home Assistant one. Open an
issue on this repository's GitHub.
