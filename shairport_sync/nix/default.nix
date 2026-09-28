/*
  Pure-Nix container root for the Shairport Sync app.

  This produces a single derivation, `containerRoot`, whose $out is a
  ready-to-use container filesystem overlay: an /etc/services.d/ tree with a
  run script per service, /etc/dbus-1, /etc/avahi, and a /sbin/init pointing
  at s6-svscan as PID 1.
  Nothing here comes from Alpine/apk or bashio/s6-overlay - only nixpkgs
  derivations plus configuration this file writes itself.

  The Dockerfile that consumes this is intentionally thin: it just runs
  `nix-build`, copies containerRoot's closure into /nix, and copies
  containerRoot's own contents (dereferenced, not as a store path) onto /.
  All the actual logic - what runs, in what order, with what config -
  lives here, in source control, not generated.

  Facts this file relies on that were verified against primary sources
  while writing it (not assumed):
    - pkgs.shairport-sync has an `enableAirplay2` option, and pkgs.nqptp
      exists, both confirmed by reading
      pkgs/by-name/sh/shairport-sync/package.nix and
      pkgs/by-name/nq/nqptp/package.nix directly at the pinned commit.
    - pkgs.s6 (s6-svscan) exists under that exact attribute name, confirmed
      by reading pkgs/top-level/all-packages.nix's `inherit (skawarePackages)
      ... s6 ...` block at the pinned commit - it moved out of the old
      pkgs/tools/system/s6 path into pkgs/development/skaware-packages at
      some point, so the attribute name (not the file path) is what's
      pinned here.
    - The dbus system.conf and avahi-dbus.conf content below is adapted
      from dbus's own bus/system.conf.in and avahi's own
      avahi-daemon/avahi-dbus.conf.in (read directly from their upstream
      git repos), with the @PLACEHOLDER@ values filled in for this
      container (root user, our own socket paths) rather than reinvented
      from memory - service-activation directives we don't need
      (<standard_system_servicedirs/>, <servicehelper>, <fork/>, <syslog/>)
      are deliberately dropped since we run everything as root, in the
      foreground, under s6.

  This has since actually been built and run, not just read: a real Nix
  toolchain built containerRoot for real (hitting cache.nixos.org for
  everything except shairport-sync itself and the small config files), a
  real Docker build produced a working `FROM scratch` image from it, and
  that image ran as a real container - dbus, avahi, nqptp and
  shairport-sync all confirmed alive together under s6-svscan, avahi
  confirmed completing real mDNS registration, and shairport-sync confirmed
  connecting to a real PulseAudio server and listening on AirPlay 2's RTSP
  port (7000). That process found and fixed six real bugs the original,
  read-only version of this file had (an unquoted-heredoc bug that broke
  the Nix build itself, s6-svscan needing an explicit scan-directory
  argument, missing NSS files, wrong avahi-daemon flags, a missing /tmp and
  $PULSE_SERVER for libpulse, and the audio backend's real name being
  "pulseaudio" not "pa") - see CHANGELOG.md's 3.0.0 entry for the full
  list. avahi/dbus's install layout (the thing the `find`-based discovery
  below was hedging against) turned out fine as discovered.

  What is still NOT verified, because it needs a real HA Supervisor
  environment or a real Apple device, neither available where this was
  built:
    - Graceful shutdown under Supervisor's actual stop/restart sequence
      (as opposed to a plain, untimed `docker stop` in testing).
    - An actual AirPlay 2 stream/pairing from a real iPhone/Mac.
  Both are documented in DOCS.md rather than assumed away.
*/
{
  nixpkgsRev ? "55d33a38f82193676603b4b58572b8718d6623b7",
  pkgs ?
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz")
      { },
}:

let
  inherit (pkgs) lib;

  shairportSync = pkgs.shairport-sync.override {
    enableAirplay2 = true;
    enableAvahi = true;
    enablePulse = true;
    enableSoxr = true;
    enableMetadata = true;
    enableStdout = true;
    enablePipe = true;
    enableDbus = false;
    enableMpris = false;
    enableMqttClient = false;
    enableAlsa = false;
    enableSndio = false;
    enableAo = false;
    enableJack = false;
    enableSoundio = false;
    enablePipewire = false;
    enableConvolution = false;
    enableLibdaemon = false;
  };

  nqptpPkg = pkgs.nqptp;

  # --- Hand-authored configs, adapted from the real upstream templates ---
  # (dbus's bus/system.conf.in and avahi's avahi-daemon/avahi-dbus.conf.in
  # and avahi-daemon/avahi-daemon.conf, fetched from their own repos while
  # writing this - not reconstructed from memory).

  dbusSystemConf = pkgs.writeText "system.conf" ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>system</type>
      <user>root</user>
      <pidfile>/run/dbus/pid</pidfile>
      <auth>EXTERNAL</auth>
      <listen>unix:path=/run/dbus/system_bus_socket</listen>

      <policy context="default">
        <allow user="*"/>
        <deny own="*"/>
        <deny send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_requested_reply="true" send_type="method_return"/>
        <allow send_requested_reply="true" send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
        <allow receive_type="signal"/>
        <allow send_destination="org.freedesktop.DBus"
               send_interface="org.freedesktop.DBus" />
        <allow send_destination="org.freedesktop.DBus"
               send_interface="org.freedesktop.DBus.Introspectable"/>
        <allow send_destination="org.freedesktop.DBus"
               send_interface="org.freedesktop.DBus.Properties"/>
      </policy>

      <policy user="root">
        <allow send_destination="org.freedesktop.DBus"
               send_interface="org.freedesktop.DBus.Monitoring"/>
      </policy>

      <!-- Populated by containerRoot below with avahi's own dbus policy
           snippet (or the fallback one in this file if it can't find one). -->
      <includedir>/etc/dbus-1/system.d</includedir>
    </busconfig>
  '';

  # Fallback avahi dbus policy, used only if the real one can't be located
  # inside the built avahi package at container-root build time.
  avahiDbusPolicyFallback = pkgs.writeText "avahi-dbus.conf" ''
    <!DOCTYPE busconfig PUBLIC
              "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
              "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <policy user="root">
        <allow own="org.freedesktop.Avahi"/>
      </policy>
      <policy context="default">
        <allow send_destination="org.freedesktop.Avahi"/>
        <allow receive_sender="org.freedesktop.Avahi"/>
        <deny send_destination="org.freedesktop.Avahi"
              send_interface="org.freedesktop.Avahi.Server" send_member="SetHostName"/>
        <deny send_destination="org.freedesktop.Avahi"
              send_interface="org.freedesktop.Avahi.Server2" send_member="SetHostName"/>
      </policy>
    </busconfig>
  '';

  # Minimal NSS files, discovered as necessary by actually running the built
  # image: dbus-daemon's config says <user>root</user>, and avahi's own real
  # dbus policy (found inside the built avahi package, not our fallback
  # above) references user "avahi" and group "netdev" - all three are
  # resolved via glibc's NSS "files" backend (getpwnam/getgrnam), which
  # fails outright ("Could not get password database information ... No
  # such file or directory") with no /etc/passwd or /etc/group at all, even
  # though the process already IS root. Nothing here ever actually drops
  # privilege (avahi runs with --no-drop-root, dbus's "run as root" is a
  # no-op since we start as root) - these entries exist purely so the NSS
  # lookups those daemons perform along the way can succeed.
  nssPasswd = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    avahi:x:999:999:Avahi mDNS daemon:/var/empty:/bin/false
  '';

  nssGroup = pkgs.writeText "group" ''
    root:x:0:
    avahi:x:999:
    netdev:x:1000:
  '';

  nsswitchConf = pkgs.writeText "nsswitch.conf" ''
    passwd: files
    group: files
  '';

  avahiDaemonConf = pkgs.writeText "avahi-daemon.conf" ''
    [server]
    use-ipv4=yes
    use-ipv6=yes
    ratelimit-interval-usec=1000000
    ratelimit-burst=1000

    [wide-area]
    #enable-wide-area=no

    [publish]
    publish-hinfo=no
    publish-workstation=no

    [reflector]
    #enable-reflector=no

    [rlimits]
  '';

  shairportSyncConfTemplate = pkgs.writeText "shairport-sync.conf.template" ''
    // Rendered at container startup by /etc/services.d/shairport-sync/run
    // from the app's options (read via jq from /data/options.json - no
    // bashio in this image). AirPlay 2 is compiled in (see
    // shairportSync.override above); nqptp (a separate service, started
    // first) provides the timing sync it needs.

    general =
    {
        name = "%%AIRPLAY_NAME%%";
        interpolation = "%%INTERPOLATION%%";
        # The backend's real name in this build is "pulseaudio", not "pa" -
        # confirmed by actually running `shairport-sync -h`, which lists
        # "Available audio backends: pulseaudio (default), pipe, stdout".
        # An earlier version of this file used "pa" (a name this build does
        # not accept at all - "fatal error: the audio backend selected:
        # \"pa\" is not supported"), caught only by actually starting the
        # daemon against a real (test) PulseAudio socket rather than just
        # reading the file.
        output_backend = "pulseaudio";
        mdns_backend = "avahi";
    %%PASSWORD_LINE%%
    };

    sessioncontrol =
    {
        allow_session_interruption = "yes";
    };

    // No "pa" settings block here: `shairport-sync -h` states outright
    // "There are no settings or options for the audio backend
    // \"pulseaudio\"" in this build, so a pa{ application_name = ...; }
    // block (present in an earlier version of this file) would be dead
    // config, not a real, effective option.
  '';

  # A tiny shared helper, sourced by every service's run script, for the
  # "wait until this file/socket exists" pattern used throughout.
  #
  # Every external command here (not a bash builtin) is called by its full
  # Nix store path, not a bare name - confirmed by actually running the
  # built image: the final container is `FROM scratch`, so there is no
  # /bin, no /usr/bin, and no PATH pointing at anything with coreutils on
  # it. A bare `sleep`/`mkdir`/`rm` fails at runtime ("command not found")
  # even though it looks completely ordinary in the script.
  waitForFn = ''
    wait_for() {
      # $1 = human label, $2 = path to stat
      i=0
      while [ ! -e "$2" ]; do
        i=$((i + 1))
        if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
          echo "[wait] still waiting for $1 ($2)..."
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done
    }
  '';

in
rec {
  inherit shairportSync nqptpPkg;

  containerRoot =
    pkgs.runCommand "shairport-sync-container-root"
      {
        nativeBuildInputs = [ pkgs.findutils ];
      }
      ''
        set -eu

        # --- Discover the real binary/config paths inside the already-built
        # avahi/dbus derivations, rather than guessing bin/ vs sbin/. ---
        AVAHI_DAEMON_BIN="$(find ${pkgs.avahi} -type f -name avahi-daemon | head -n1)"
        DBUS_DAEMON_BIN="$(find ${pkgs.dbus} -type f -name dbus-daemon | head -n1)"
        if [ -z "$AVAHI_DAEMON_BIN" ] || [ -z "$DBUS_DAEMON_BIN" ]; then
          echo "ERROR: could not locate avahi-daemon or dbus-daemon binary in the built packages" >&2
          exit 1
        fi

        AVAHI_DBUS_POLICY="$(find ${pkgs.avahi} -type f -name 'avahi-dbus.conf' 2>/dev/null | head -n1)"
        if [ -z "$AVAHI_DBUS_POLICY" ]; then
          echo "NOTE: avahi package did not ship its own avahi-dbus.conf where expected; using the fallback bundled in this repo's nix/default.nix" >&2
          AVAHI_DBUS_POLICY="${avahiDbusPolicyFallback}"
        fi

        mkdir -p "$out"/etc/dbus-1/system.d
        mkdir -p "$out"/etc/avahi
        mkdir -p "$out"/etc/services.d/dbus
        mkdir -p "$out"/etc/services.d/avahi
        mkdir -p "$out"/etc/services.d/nqptp
        mkdir -p "$out"/etc/services.d/shairport-sync
        mkdir -p "$out"/sbin
        mkdir -p "$out"/usr/local/bin
        # libpulse wants a world-writable /tmp for its own scratch files
        # (a random per-connection directory) even when told to connect to
        # an explicit unix socket via $PULSE_SERVER - confirmed by actually
        # connecting shairport-sync to a real PulseAudio server: without
        # this, it fails before even attempting the socket, with "Failed to
        # create random directory /tmp/pulse-XXXXXXXX: No such file or
        # directory" (this image has no /tmp at all otherwise - FROM
        # scratch starts completely empty).
        mkdir -p "$out"/tmp
        chmod 1777 "$out"/tmp

        cp "${dbusSystemConf}" "$out"/etc/dbus-1/system.conf
        cp "$AVAHI_DBUS_POLICY" "$out"/etc/dbus-1/system.d/avahi-dbus.conf
        cp "${avahiDaemonConf}" "$out"/etc/avahi/avahi-daemon.conf
        cp "${shairportSyncConfTemplate}" "$out"/etc/shairport-sync.conf.template
        cp "${nssPasswd}" "$out"/etc/passwd
        cp "${nssGroup}" "$out"/etc/group
        cp "${nsswitchConf}" "$out"/etc/nsswitch.conf

        ln -s "${lib.getExe pkgs.nqptp}" "$out"/usr/local/bin/nqptp
        ln -s "${lib.getExe shairportSync}" "$out"/usr/local/bin/shairport-sync

        # PID 1: s6-svscan supervising /etc/services.d, restarting anything
        # that exits (its default behavior for any dir it scans - no per-service
        # "type" file needed, unlike the s6-rc layer this deliberately skips).
        ln -s "${pkgs.s6}/bin/s6-svscan" "$out"/sbin/init

        # NOTE ON QUOTING: every heredoc below uses a QUOTED delimiter
        # (<<'RUNEOF') so bash writes its body to disk byte-for-byte with
        # NO shell expansion of its own - the only substitution that ever
        # happens is Nix's own dollar-brace interpolation, which is resolved
        # while this string is still being built by Nix, before bash even
        # sees the heredoc. That's deliberate: an earlier, unquoted-heredoc
        # version of this file let bash try to expand $1/$2 from
        # `waitForFn`'s literal body against the *builder's own*
        # environment (where they're unset), which failed under `set -eu`
        # with "$1: unbound variable" - caught by actually building this
        # with Nix rather than only reading the file. The two binary paths
        # discovered above via `find` (only known once the shell runs, so
        # Nix can't interpolate them) are instead written as @PLACEHOLDER@
        # tokens and substituted with `sed` after each heredoc, which needs
        # no escaping and can't reintroduce the same bug.

        # --- dbus ---
        cat > "$out"/etc/services.d/dbus/run <<'RUNEOF'
        #!${pkgs.bash}/bin/bash
        set -e
        ${pkgs.coreutils}/bin/mkdir -p /run/dbus
        ${pkgs.coreutils}/bin/rm -f /run/dbus/pid
        echo "[dbus] starting"
        exec "@DBUS_DAEMON_BIN@" --config-file=/etc/dbus-1/system.conf --nofork --nopidfile
        RUNEOF
        ${pkgs.gnused}/bin/sed -i "s|@DBUS_DAEMON_BIN@|$DBUS_DAEMON_BIN|" "$out"/etc/services.d/dbus/run

        # --- avahi (waits for dbus's socket) ---
        cat > "$out"/etc/services.d/avahi/run <<'RUNEOF'
        #!${pkgs.bash}/bin/bash
        set -e
        ${waitForFn}
        wait_for "dbus system bus" /run/dbus/system_bus_socket
        ${pkgs.coreutils}/bin/mkdir -p /run/avahi-daemon
        echo "[avahi] starting"
        # No `--no-chroot` (this nixpkgs build of avahi-daemon doesn't
        # accept it - `avahi-daemon --help` doesn't list it) and no `-f`
        # (that flag means "load THIS config file instead", not
        # "foreground" - avahi-daemon already runs in the foreground by
        # default unless told to --daemonize). Both found by actually
        # running this and reading `avahi-daemon --help`, not assumed.
        exec "@AVAHI_DAEMON_BIN@" --no-drop-root --no-rlimits
        RUNEOF
        ${pkgs.gnused}/bin/sed -i "s|@AVAHI_DAEMON_BIN@|$AVAHI_DAEMON_BIN|" "$out"/etc/services.d/avahi/run

        # --- nqptp (no dependencies - just needs to be up before shairport-sync) ---
        cat > "$out"/etc/services.d/nqptp/run <<'RUNEOF'
        #!${pkgs.bash}/bin/bash
        set -e
        echo "[nqptp] starting"
        exec ${lib.getExe pkgs.nqptp}
        RUNEOF

        # --- shairport-sync (waits for avahi, nqptp, and the Supervisor's
        # PulseAudio socket; renders its own config from /data/options.json) ---
        cat > "$out"/etc/services.d/shairport-sync/run <<'RUNEOF'
        #!${pkgs.bash}/bin/bash
        set -e
        ${waitForFn}
        wait_for "avahi" /run/avahi-daemon/pid
        wait_for "PulseAudio socket" /run/audio/pulse.sock
        # Point libpulse straight at the Supervisor's socket. The official
        # Alpine app base image apparently bakes an /etc/pulse/client.conf
        # default-server setting that add-ons built FROM it inherit for
        # free (confirmed indirectly: the real home-assistant/addons vlc
        # add-on's own rootfs sets no PULSE_SERVER and has no client.conf
        # of its own, yet connects); this image has no base image at all,
        # so nothing sets that default - confirmed by actually connecting
        # to a real PulseAudio server without it and getting "Connection
        # refused". $PULSE_SERVER is a standard libpulse client env var.
        export PULSE_SERVER=unix:/run/audio/pulse.sock
        # nqptp has no readiness file of its own; give it a moment to bind
        # 319/320 before shairport-sync starts expecting it. See DOCS.md -
        # this is a fixed delay, not a real readiness check, because nqptp
        # doesn't expose one.
        ${pkgs.coreutils}/bin/sleep 2

        OPTIONS=/data/options.json
        AIRPLAY_NAME=$(${pkgs.jq}/bin/jq -r '.airplay_name // "Home Assistant"' "$OPTIONS")
        INTERPOLATION=$(${pkgs.jq}/bin/jq -r '.interpolation // "soxr"' "$OPTIONS")
        PASSWORD=$(${pkgs.jq}/bin/jq -r '.password // ""' "$OPTIONS")

        PASSWORD_LINE=""
        if [ -n "$PASSWORD" ]; then
          PASSWORD_LINE="    password = \"$PASSWORD\";"
        fi

        ${pkgs.gnused}/bin/sed \
          -e "s|%%AIRPLAY_NAME%%|$AIRPLAY_NAME|" \
          -e "s|%%INTERPOLATION%%|$INTERPOLATION|" \
          -e "s|%%PASSWORD_LINE%%|$PASSWORD_LINE|" \
          /etc/shairport-sync.conf.template > /etc/shairport-sync.conf

        echo "[shairport-sync] starting (AirPlay name: $AIRPLAY_NAME)"
        exec ${lib.getExe shairportSync} -c /etc/shairport-sync.conf
        RUNEOF

        chmod +x "$out"/etc/services.d/*/run
      '';
}
