/*
  Pure-Nix container root for the Shairport Sync app: an /etc/services.d/ tree
  with a run script per service, /etc/dbus-1, /etc/avahi, and /sbin/init
  pointing at s6-svscan as PID 1. The Dockerfile only builds this, copies the
  closure to /nix and copies these contents onto /.
*/
{
  # TEMPORARY: a nixpkgs fork. It carries glibSupport for avahi and
  # pulseaudio, pulseaudio's libOnly module fix, flac's enableDocs, sqlite's
  # checkTarget, shairport-sync's glib gating and its L16 patch - all needed
  # below and none upstream yet. The URL stays NixOS/nixpkgs because GitHub
  # serves fork-network commits from the upstream archive endpoint, after a
  # short propagation delay.
  nixpkgsRev ? "16b0cbc9754e848a4ea46fccb9b511b7d0c9622b",
  pkgs ?
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz")
      { },
}:

let
  inherit (pkgs) lib;

  # musl rather than glibc: 4MB against 47MB. Safe because this image needs
  # getpwnam/getgrnam over the /etc/passwd and /etc/group written below, not
  # pluggable NSS modules. Dynamic rather than pkgsStatic because four daemons
  # would each get their own copy of the shared dependencies. Nothing in this
  # stack is in cache.nixos.org, so the image depends on this project's own
  # binary cache.
  mpkgs = pkgs.pkgsMusl.extend (
    _final: prev: {
      # enableSystemd pulls systemd-minimal + libs (38MB) for activation and
      # journal logging; dbus runs under s6 with the activation directives
      # stripped out of system.conf. Overriding here rather than per-consumer
      # keeps avahi and libpulseaudio, which also link libdbus, in agreement.
      # x11Support is for dbus-launch's X11 autolaunch; the rest are
      # unreachable without a policy, an auditd, or any privilege to drop.
      dbus = prev.dbus.override {
        enableSystemd = false;
        x11Support = false;
        apparmorSupport = false;
        libauditSupport = false;
        capabilitySupport = false;
      };

      # Build-time only: meson is a buildPythonApplication and ninja's docs
      # phase pulls in asciidoc. Must be an overlay entry - `meson.override
      # { python3 = ...; }` is a no-op, since python3.pkgs stays bound to the
      # original interpreter.
      python3 = prev.python3.override {
        withMinimalDeps = true;
        # Every wheel is a deflate-compressed zip, so flit-core fails without
        # zlib. expat and libffi are insurance for the build tooling.
        withZlib = true;
        withExpat = true;
        withLibffi = true;
        # withOpenssl stays off: builds are offline, and it cannot be
        # allowlisted anyway - allowedReferenceNames resolves a name to that
        # package's default output, `bin` for openssl, while _ssl links libssl
        # from `out`. Anything re-enabled above must be listed here, or
        # withMinimalDeps' reference check rejects it.
        allowedReferenceNames = [
          "bashNonInteractive"
          "zlib"
          "expat"
          "libffi"
        ];
      };

      # fftw needs gfortran, which does not build under musl; speexdsp falls
      # back to its bundled FFT.
      speexdsp = prev.speexdsp.override { withFftw3 = false; };

      # pam_cap pulls linux-pam, which pulls systemd-minimal-libs.
      libcap = prev.libcap.override { usePam = false; };

      # flac's API docs need doxygen and graphviz, and graphviz -> gts -> glib.
      flac = prev.flac.override { enableDocs = false; };

      # ffmpegTrimFlags only covers external libraries; ffmpeg still compiles
      # its whole built-in component set, which is why libavcodec.so alone is
      # 15.6MB. Appending --disable-everything clears it, leaving the three
      # decoders shairport-sync can reach:
      #   aac       - AirPlay 2 buffered audio
      #   alac      - AirPlay 2 realtime audio and classic AirPlay 1
      #   pcm_s16be - classic senders announcing uncompressed L16/44100/2,
      #               which is what pyatv and Home Assistant's own AirPlay
      #               media player send. Needs the pinned revision's backport
      #               of shairport-sync be30b6b2.
      # overrideAttrs only because nixpkgs' ffmpeg has no extraConfigureFlags.
      ffmpeg = (prev.ffmpeg-headless.override ffmpegTrimFlags).overrideAttrs (o: {
        configureFlags = (o.configureFlags or [ ]) ++ [
          "--disable-everything"
          "--enable-decoder=aac,aac_fixed,alac,pcm_s16be"
          "--enable-parser=aac"
        ];
      });

      # Both ship optional glib binding libraries nothing here loads, whose
      # existence alone puts glib (17MB) in the runtime closure.
      avahi = prev.avahi.override { glibSupport = false; };
      libpulseaudio = prev.libpulseaudio.override { glibSupport = false; };
    }
  );

  # Nearly every ffmpeg with* flag defaults to one of withHeadlessDeps /
  # withSmallDeps / withFullDeps, and ffmpeg-headless is the variant that sets
  # the first. Turning it off drops every external library, the non-library
  # feature payload, the documentation and the executables in one move, so
  # anything nixpkgs adds to those tiers later stays off by default. Only what
  # shairport-sync's DT_NEEDED actually names comes back.
  ffmpegTrimFlags = {
    withHeadlessDeps = false;
    buildAvcodec = true;
    buildAvformat = true;
    buildAvutil = true;
    buildSwresample = true;
    # Bounds checking on data arriving off the network, not a feature payload.
    withSafeBitstreamReader = true;
  };

  # pkgs.bash is bash-interactive, which brings readline and ncurses (~19MB).
  bash = mpkgs.bashNonInteractive;

  shairportSync = mpkgs.shairport-sync.override {
    enableAirplay2 = true;
    enableAvahi = true;
    enablePulse = true;
    enableSoxr = true;
    enableMetadata = true;
    enableStdout = true;
    enablePipe = true;
    # Before enabling either: nixpkgs' shairport-sync has an unconditional
    # postPatch rewriting G_BUS_TYPE_SYSTEM to G_BUS_TYPE_SESSION, and this
    # image runs a system bus only. Undo that postPatch too.
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

  nqptpPkg = mpkgs.nqptp;

  # Adapted from dbus's bus/system.conf.in, with the service-activation
  # directives dropped: everything runs as root, in the foreground, under s6.
  dbusSystemConf = mpkgs.writeText "system.conf" ''
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

      <includedir>/etc/dbus-1/system.d</includedir>
    </busconfig>
  '';

  avahiDbusPolicyFallback = mpkgs.writeText "avahi-dbus.conf" ''
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

  # dbus's config names root; avahi's policy names avahi and netdev. Those
  # lookups fail with no passwd/group file at all, even running as root.
  nssPasswd = mpkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    avahi:x:999:999:Avahi mDNS daemon:/var/empty:/bin/false
  '';

  nssGroup = mpkgs.writeText "group" ''
    root:x:0:
    avahi:x:999:
    netdev:x:1000:
  '';

  # A glibc concept, ignored by musl; kept in case this is pointed back at it.
  nsswitchConf = mpkgs.writeText "nsswitch.conf" ''
    passwd: files
    group: files
  '';

  avahiDaemonConf = mpkgs.writeText "avahi-daemon.conf" ''
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

  shairportSyncConfTemplate = mpkgs.writeText "shairport-sync.conf.template" ''
    general =
    {
        name = "%%AIRPLAY_NAME%%";
        interpolation = "%%INTERPOLATION%%";
        output_backend = "pulseaudio";
        mdns_backend = "avahi";
    %%PASSWORD_LINE%%
    };

    sessioncontrol =
    {
        allow_session_interruption = "yes";
    };
  '';

  # Full store paths throughout: FROM scratch has no /bin and no PATH.
  waitForFn = ''
    wait_for() {
      i=0
      while [ ! -e "$2" ]; do
        i=$((i + 1))
        if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
          echo "[wait] still waiting for $1 ($2)..."
        fi
        ${mpkgs.coreutils}/bin/sleep 1
      done
    }
  '';

in
rec {
  inherit shairportSync nqptpPkg;
  inherit mpkgs;

  containerRoot =
    mpkgs.runCommand "shairport-sync-container-root"
      {
        nativeBuildInputs = [ mpkgs.findutils ];
      }
      ''
        set -eu

        AVAHI_DAEMON_BIN="$(find ${mpkgs.avahi} -type f -name avahi-daemon | head -n1)"
        DBUS_DAEMON_BIN="$(find ${mpkgs.dbus} -type f -name dbus-daemon | head -n1)"
        if [ -z "$AVAHI_DAEMON_BIN" ] || [ -z "$DBUS_DAEMON_BIN" ]; then
          echo "ERROR: could not locate avahi-daemon or dbus-daemon binary in the built packages" >&2
          exit 1
        fi

        AVAHI_DBUS_POLICY="$(find ${mpkgs.avahi} -type f -name 'avahi-dbus.conf' 2>/dev/null | head -n1)"
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
        # libpulse creates a random per-connection directory here even when
        # given an explicit socket, and FROM scratch has no /tmp.
        mkdir -p "$out"/tmp
        chmod 1777 "$out"/tmp

        cp "${dbusSystemConf}" "$out"/etc/dbus-1/system.conf
        cp "$AVAHI_DBUS_POLICY" "$out"/etc/dbus-1/system.d/avahi-dbus.conf
        cp "${avahiDaemonConf}" "$out"/etc/avahi/avahi-daemon.conf
        cp "${shairportSyncConfTemplate}" "$out"/etc/shairport-sync.conf.template
        cp "${nssPasswd}" "$out"/etc/passwd
        cp "${nssGroup}" "$out"/etc/group
        cp "${nsswitchConf}" "$out"/etc/nsswitch.conf

        ln -s "${lib.getExe mpkgs.nqptp}" "$out"/usr/local/bin/nqptp
        ln -s "${lib.getExe shairportSync}" "$out"/usr/local/bin/shairport-sync
        ln -s "${mpkgs.s6}/bin/s6-svscan" "$out"/sbin/init

        # Quoted heredoc delimiters throughout: unquoted, bash expands
        # waitForFn's $1/$2 against the builder's environment and the build
        # fails under `set -eu`. The two paths found above are only known once
        # this shell runs, so they go in as tokens and are sed'd afterwards.

        cat > "$out"/etc/services.d/dbus/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        ${mpkgs.coreutils}/bin/mkdir -p /run/dbus
        ${mpkgs.coreutils}/bin/rm -f /run/dbus/pid
        echo "[dbus] starting"
        exec "@DBUS_DAEMON_BIN@" --config-file=/etc/dbus-1/system.conf --nofork --nopidfile
        RUNEOF
        ${mpkgs.gnused}/bin/sed -i "s|@DBUS_DAEMON_BIN@|$DBUS_DAEMON_BIN|" "$out"/etc/services.d/dbus/run

        cat > "$out"/etc/services.d/avahi/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        ${waitForFn}
        wait_for "dbus system bus" /run/dbus/system_bus_socket
        ${mpkgs.coreutils}/bin/mkdir -p /run/avahi-daemon
        echo "[avahi] starting"
        # This build has no --no-chroot, and -f means "load THIS config file",
        # not "foreground" - which is already the default.
        exec "@AVAHI_DAEMON_BIN@" --no-drop-root --no-rlimits
        RUNEOF
        ${mpkgs.gnused}/bin/sed -i "s|@AVAHI_DAEMON_BIN@|$AVAHI_DAEMON_BIN|" "$out"/etc/services.d/avahi/run

        cat > "$out"/etc/services.d/nqptp/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        echo "[nqptp] starting"
        exec ${lib.getExe mpkgs.nqptp}
        RUNEOF

        cat > "$out"/etc/services.d/shairport-sync/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        ${waitForFn}
        wait_for "avahi" /run/avahi-daemon/pid
        wait_for "PulseAudio socket" /run/audio/pulse.sock
        # Apps built FROM the Alpine base image inherit a client.conf
        # default-server; this image has no base image.
        export PULSE_SERVER=unix:/run/audio/pulse.sock
        # nqptp exposes no readiness file, so this is a fixed delay.
        ${mpkgs.coreutils}/bin/sleep 2

        OPTIONS=/data/options.json
        AIRPLAY_NAME=$(${mpkgs.jq}/bin/jq -r '.airplay_name // "Home Assistant"' "$OPTIONS")
        INTERPOLATION=$(${mpkgs.jq}/bin/jq -r '.interpolation // "soxr"' "$OPTIONS")
        PASSWORD=$(${mpkgs.jq}/bin/jq -r '.password // ""' "$OPTIONS")

        PASSWORD_LINE=""
        if [ -n "$PASSWORD" ]; then
          PASSWORD_LINE="    password = \"$PASSWORD\";"
        fi

        ${mpkgs.gnused}/bin/sed \
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
