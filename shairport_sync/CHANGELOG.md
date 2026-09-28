# Changelog

## 3.0.0

- **Breaking (architecture):** the whole image is now built by Nix, not just
  `shairport-sync`/`nqptp`. `avahi`, `dbus`, and process supervision are all
  defined in a new `nix/default.nix` and built from source too, using plain
  `s6` (`s6-svscan` as PID 1) instead of the `s6-overlay`/`s6-rc`/`bashio`
  stack 1.0.0/2.0.0 used. The final image is `FROM scratch` - there is no
  Alpine base image underneath it anymore.
- Removes `rootfs/` (the old s6-overlay service tree and shell templating)
  and `build.yaml` (`BUILD_FROM`/the official Alpine app base image is no
  longer used at all) - superseded by `nix/default.nix` and the rewritten
  `Dockerfile`.
- dbus's `system.conf` and avahi's D-Bus policy/`avahi-daemon.conf` are now
  hand-adapted from their own real upstream config templates (rather than
  Alpine's `apk` packaging defaults), simplified for a single-user,
  no-D-Bus-activation container. See `nix/default.nix`'s header comment for
  exactly what was adapted from where.
- Measured cost of the above (not the originally-feared "compiles ffmpeg
  from source"): only `shairport-sync` itself and four small config files
  actually compile; `avahi`/`dbus`/`s6`/`nqptp`/`jq`/`gnused`/ffmpeg/etc.
  came straight from `cache.nixos.org` in testing. See DOCS.md.
- **Actually built and run**, not just written: a real Nix + Docker
  toolchain built the real Dockerfile end-to-end into a working `FROM
  scratch` image, run as a container against a real PulseAudio server,
  with `dbus`/`avahi`/`nqptp`/`shairport-sync` all confirmed alive together
  under `s6-svscan` and shairport-sync confirmed listening on AirPlay 2's
  RTSP port (7000). That process found and fixed six real bugs a read-only
  review had missed:
  - The four generated service `run` scripts used unquoted heredocs
    (`<<EOF`), so bash tried to expand `$1`/`$2` from the embedded
    `wait_for` helper *at Nix-build time*, against the builder's own
    (unset) environment, failing the build outright with `$1: unbound
    variable`. Fixed by quoting the heredoc delimiters (`<<'RUNEOF'`) and
    substituting the two genuinely build-time-discovered binary paths with
    a `sed` pass afterwards instead.
  - `s6-svscan` takes its scan directory as a required argument - it has
    no default - so the container exited immediately with a usage error.
    Fixed in the Dockerfile's `ENTRYPOINT`.
  - The image ships no `/etc/passwd`, `/etc/group`, or `/etc/nsswitch.conf`
    at all, so glibc's NSS couldn't resolve the `root`/`avahi` users or
    `netdev` group referenced by dbus's and avahi's own policy files, even
    though everything already runs as root. Fixed with minimal, hand-added
    NSS files.
  - `avahi-daemon` in this build doesn't accept `--no-chroot`, and `-f`
    means "load this config file" (requires an argument), not
    "foreground" - both wrong assumptions in the original run script,
    found via `avahi-daemon --help`.
  - libpulse needs a world-writable `/tmp` for its own scratch files (this
    `FROM scratch` image had none) and doesn't default to the Supervisor's
    `/run/audio/pulse.sock` on its own - `$PULSE_SERVER` has to be set
    explicitly, something the official Alpine app base image apparently
    provides for free via its own `/etc/pulse/client.conf` that a
    from-scratch image doesn't inherit.
  - The audio backend's real name in this build is `"pulseaudio"`, not
    `"pa"` - `output_backend = "pa"` failed outright with "audio backend
    ... is not supported". The `pa { application_name = ...; }` config
    block was also removed: this backend takes no settings at all.
  Also rebuilt and re-run under **podman** (with `--network host` and
  `--cap-add SYS_NICE`, approximating this app's real `host_network`/
  `realtime` options) as a cross-runtime check, since Supervisor's actual
  Docker wasn't available to test against directly: confirmed nqptp bound
  to the real host's UDP 319/320 and shairport-sync listening on the real
  host's TCP 7000 via `ss`, with avahi registering on the actual host
  network interfaces rather than a container bridge. See DOCS.md.
  Two things remain genuinely untested (no real Supervisor environment or
  Apple device in the sandbox): graceful shutdown under Supervisor's own
  stop/restart sequence, and an actual AirPlay 2 stream from a real
  device. See DOCS.md.

## 2.0.0

- **Breaking (build behavior):** now builds `shairport-sync` and `nqptp`
  via a Nix multi-stage Dockerfile, pinned to nixpkgs commit
  `55d33a38f82193676603b4b58572b8718d6623b7`, instead of `apk add
  shairport-sync`. This gets full **AirPlay 2** support
  (`--with-airplay-2`), which Alpine's packaged binary does not include.
- Adds a new `nqptp` s6 service (AirPlay 2's timing/sync companion daemon),
  started before `shairport-sync`.
- Trims unused shairport-sync backends (ALSA, sndio, JACK, PipeWire, ao,
  soundio, MQTT, D-Bus/MPRIS) to shrink the from-source build; keeps
  avahi (mDNS) and PulseAudio (output) plus soxr/metadata.
- Cost of the above: this override combination is very unlikely to be in
  nixpkgs' binary cache, so a fresh install now compiles ffmpeg, openssl,
  shairport-sync and nqptp from source. Expect a much slower, heavier
  first install than 1.0.0. See DOCS.md / README.md.

## 1.0.0

- Initial release. Classic AirPlay (AirPlay 1) receiver backed by Alpine's
  packaged `shairport-sync`, outputting to the Supervisor's PulseAudio
  container via the native `pa` backend.
