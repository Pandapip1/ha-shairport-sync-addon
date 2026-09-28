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

  It has since also run on a real Home Assistant OS 18.3 Supervisor
  (aarch64), installed and driven through the Supervisor API: built by
  Supervisor's own `docker buildx build`, started and stopped through its
  lifecycle, with nqptp confirmed on the real host's UDP 319/320 and
  shairport-sync on the real host's TCP 7000. Graceful shutdown - listed
  here as unverified in 3.0.0 - measured 220-270ms. That round also caught
  a `config.yaml` `timeout` value Supervisor rejects outright, which made
  the app invisible in the Add-on Store; see CHANGELOG.md.

  What is still NOT verified, because it needs a real Apple device:
    - An actual AirPlay 2 stream/pairing from a real iPhone/Mac.
  Documented in DOCS.md rather than assumed away.
*/
{
  # TEMPORARY: this points at a nixpkgs *fork*, not upstream, because the
  # trimming below needs package options that do not exist upstream yet:
  #   avahi         glibSupport      (drops libavahi-glib/libavahi-gobject)
  #   pulseaudio    glibSupport      (drops libpulse-mainloop-glib + gsettings)
  #   pulseaudio    libOnly modules  (lib/pulse-* glob never matched
  #                                   lib/pulseaudio, so a library-only build
  #                                   shipped 67 daemon modules and a runtime
  #                                   reference to fftw)
  #   flac          enableDocs       (doxygen+graphviz -> gts -> glib, purely
  #                                   to build flac's own API docs)
  #   sqlite        checkTarget      (its test target builds ASan/UBSan
  #                                   fuzzcheck binaries, which musl cannot)
  #   shairport-sync glib gating     (glib is only needed for D-Bus/MPRIS,
  #                                   but was an unconditional Linux input)
  # Without these, each one has to be reproduced as a fragile `overrideAttrs`
  # here instead. Bump this to an upstream commit once they land.
  #
  # The URL stays NixOS/nixpkgs even though this revision currently only
  # exists on a fork: GitHub serves any commit in a fork network from the
  # upstream repository's archive endpoint. Note there is a short
  # propagation delay after a push - immediately after 28aa53e2 was pushed
  # the upstream URL briefly 404'd while the fork's returned 200, then both
  # returned an identical 52828869-byte tarball a moment later. So a 404
  # here right after pushing means "wait", not "wrong URL".
  nixpkgsRev ? "8894653cb54b428b9b953b3418496c8cf1f53330",
  pkgs ?
    import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz")
      { },
}:

let
  inherit (pkgs) lib;

  # --- Everything in the image is built against musl, not glibc ---
  # glibc's store path is 47MB, of which only about 5MB is the libraries
  # actually loaded: lib/gconv is 21MB (255 charset-conversion modules),
  # share/i18n 17MB and share/locale 5MB. musl's whole closure is 4MB and
  # has no gconv or locale tree at all.
  #
  # Why this is safe despite this image needing name lookups: what it
  # actually needs is getpwnam/getgrnam for the root/avahi users and netdev
  # group that dbus's and avahi's own policy files name (see the NSS notes
  # further down). It does NOT need pluggable NSS modules - nss-mdns is
  # deliberately absent. musl has no NSS mechanism at all; its
  # getpwnam/getgrnam parse /etc/passwd and /etc/group directly, which is
  # exactly the lookup performed here, so the static /etc/passwd and
  # /etc/group written below still satisfy it. (/etc/nsswitch.conf is a
  # glibc concept and is simply ignored by musl; it is kept so the same
  # container root still works if this is ever pointed back at glibc.)
  #
  # The price, measured rather than assumed: none of this is in
  # cache.nixos.org - pkgsMusl.dbus, pkgsMusl.avahi and
  # pkgsMusl.shairport-sync all 404 there - so the whole stack compiles
  # from source and the image depends entirely on this project's own binary
  # cache (see the Dockerfile's extra-substituters).
  #
  # Dynamic musl rather than pkgsStatic deliberately: this image runs four
  # separate daemons (dbus, avahi, nqptp, shairport-sync), so static
  # linking would duplicate their shared dependencies into every
  # executable. Static would also make the dbus override below impossible
  # to apply after the fact - nixpkgs' replaceDependencies is a byte-level
  # sed over the NAR (see pkgs/build-support/replace-direct-dependencies.nix),
  # so it can only repoint real dynamic references, never relink code that
  # has been copied into a static binary.
  #
  # dbus's `enableSystemd` still defaults on even under musl (checked:
  # nixpkgs reports systemdMinimal as available on musl, and pkgsMusl.dbus
  # still lists it), and it pulls systemd-minimal + systemd-minimal-libs
  # (38MB) purely for systemd activation and journal logging, neither of
  # which is reachable in this image - dbus runs under s6 with the
  # activation directives stripped out of system.conf. Overriding it in an
  # overlay rather than per-consumer means avahi and libpulseaudio, which
  # link libdbus too, agree with our daemon automatically.
  mpkgs = pkgs.pkgsMusl.extend (
    _final: prev: {
      # x11Support defaults on for Linux and exists only for dbus-launch's X11
      # autolaunch, which needs an X display. This image has none, and dbus is
      # started explicitly by s6 as a system bus, so autolaunch can never fire.
      # It was pulling libx11 (4MB) + libxcb (3MB) into the closure.
      # NOT overriding python3 to python3Minimal here, tempting as it looks:
      # dbus's meson does an unconditional `find_program('python3')` for three
      # scripts that import nothing beyond `os`, and python3Minimal has one
      # buildInput (bash) against full CPython's sixteen. But dbus also takes
      # meson, and nixpkgs builds meson as a python3.pkgs.buildPythonApplication,
      # so full CPython - and with it sqlite - is in the build regardless.
      # Pointing dbus at the minimal interpreter therefore built *both*:
      # evaluating dbus's nativeBuildInputs listed meson-1.10.2 and
      # python3-minimal-3.14.7 side by side. Reusing the interpreter meson
      # already forces is strictly cheaper.
      #
      # AppArmor mediation, audit logging and capability dropping are all
      # unreachable here: this container has no AppArmor policy, no auditd to
      # log to, and dbus already runs as root under s6 with no privilege to
      # drop. They were pulling libapparmor, audit and libcap-ng (~3MB).
      dbus = prev.dbus.override {
        enableSystemd = false;
        x11Support = false;
        apparmorSupport = false;
        libauditSupport = false;
        capabilitySupport = false;
      };

      # Nothing in this image ships Python - it is here purely because meson
      # is a python3.pkgs.buildPythonApplication, and dbus/avahi/libpulseaudio
      # are all meson-built. So CPython is pure build cost, and a large one:
      # full CPython pulls sixteen buildInputs and compiles its whole stdlib
      # and test suite.
      #
      # Note this MUST be an overlay entry rather than `meson.override
      # { python3 = ...; }` - verified that the latter is a no-op, producing a
      # byte-identical meson derivation, because `python3.pkgs` stays bound to
      # the original interpreter regardless of the argument. Overriding
      # `python3` in the overlay does reach meson (different drv hash).
      #
      # Switching off individual modules, rather than `withMinimalDeps = true`
      # plus re-adds. That deny-by-default shape was tried and is not
      # workable: cpython gates
      #     bzip2  libffi  libuuid  ncurses  xz  zlib
      # solely on `!withMinimalDeps`, with no per-module flag, so there is no
      # way to put zlib back - and every Python wheel is a deflate-compressed
      # zip, so the build died in flit-core with
      #     RuntimeError: Compression requires the (missing) zlib module
      # That is also why python3Minimal is a bootstrap-only interpreter: it
      # cannot build wheels at all.
      #
      # (An earlier attempt at the same shape failed differently, on an
      # output reference check - withMinimalDeps sets allowedReferenceNames
      # to ["bashNonInteractive"], and cpython's passthru re-override used to
      # drop that argument because it filtered inputs to scalar types. The
      # pinned revision fixes that, but the zlib problem above is
      # independent of it and fatal on its own.)
      # CPython is here only as a *build* tool - meson is a Python
      # application, and ninja's unconditional docs phase drags in asciidoc,
      # which is another one. Verified it is build-time only rather than
      # assumed: `nix-store -qR` on the built containerRoot matches zero
      # python paths out of 140, so none of this reaches the image. What it
      # costs is build time and build-host disk, which is worth cutting
      # anyway since almost everything compiled here is this subtree.
      #
      # Stated additively, the same way as ffmpeg above: withMinimalDeps
      # turns off every optional dependency at once (sqlite - whose test
      # target builds ASan/UBSan fuzzcheck binaries musl cannot;
      # gdbm; readline+ncurses; bzip2; xz; zstd; libuuid; mpdecimal; bluez;
      # tzdata; mailcap/mimetypes) and also flips the strip* flags
      # (stripConfig, stripTests, stripIdlelib, stripTkinter) plus
      # rebuildBytecode and includeSiteCustomize, none of which a build-only
      # interpreter needs. Then only what the build tooling genuinely needs
      # comes back.
      #
      # This shape is only possible as of the pinned revision: before it,
      # the optional-dependency flags were readable but not independently
      # settable, because cpython's passthru `inputs'` filter allowlisted
      # scalar types only and silently dropped allowedReferenceNames.
      python3 = prev.python3.override {
        withMinimalDeps = true;
        # zlib is not optional in practice: flit-core fails outright with
        # "RuntimeError: Compression requires the (missing) zlib module"
        # when building a wheel without it.
        withZlib = true;
        # expat (xml.parsers.expat, and so xml.etree) and libffi (ctypes)
        # are re-enabled as cheap insurance for the build tooling rather
        # than from a measured failure; both are already in this build for
        # other reasons (dbus needs expat) and neither reaches the image.
        withExpat = true;
        withLibffi = true;
        # withOpenssl (_ssl/_hashlib) is deliberately NOT re-enabled. Nothing
        # here needs TLS - every build is offline - and hashlib still works
        # without it, since CPython keeps built-in _md5/_sha1/_sha2/_sha3.
        # There is also a latent nixpkgs wart in the way: allowedReferenceNames
        # maps a name to `inputs.<name>`, which is a package's *default*
        # output. openssl's outputs are [ bin dev out man ], so that yields
        # openssl-bin while CPython's _ssl module links libssl from openssl.out
        # - the allowlist entry would not match the actual reference and the
        # check would reject the dependency it was asked to permit. Any
        # multi-output dependency whose lib output is not the default output
        # has the same problem; zlib, expat and libffi happen not to.
        # withMinimalDeps sets allowedReferences to bashNonInteractive only,
        # which is the point of it: it makes an accidental dependency a build
        # failure rather than a silent closure member. The four re-enabled
        # deps have to be declared here too, or the reference check rejects
        # the very thing that was just asked for.
        allowedReferenceNames = [
          "bashNonInteractive"
          "zlib"
          "expat"
          "libffi"
        ];
      };

      # speexdsp (a libpulseaudio dependency, used for resampling) defaults
      # to fftw for its FFT, and fftw needs gfortran - which does not build
      # under musl at all, its stage1-gcc failing outright. That was the
      # single reason the whole musl build died. speexdsp has a real flag
      # for this and falls back to its own bundled FFT, so no override of
      # libpulseaudio's inputs is needed. Traced with `nix why-depends
      # --derivation`: shairport-sync -> libpulseaudio -> speexdsp ->
      # fftw-single -> gfortran.
      speexdsp = prev.speexdsp.override { withFftw3 = false; };


      # libcap builds a PAM module (pam_cap) by default, and linux-pam drags
      # in systemd-minimal-libs. This image has no login path of any kind,
      # so PAM is unreachable; this was the last build-time reason systemd
      # appeared in the plan at all (libpulseaudio propagates libcap, and
      # libcap -> linux-pam -> systemd-minimal-libs).
      libcap = prev.libcap.override { usePam = false; };

      # flac depends on doxygen and graphviz purely to build its own API
      # documentation, and graphviz drags in gts, which drags in glib. That
      # was the real reason glib's whole closure still had to be *built*
      # after the binding libraries above were disabled - traced with
      # `nix why-depends --derivation`:
      #   shairport-sync -> libpulseaudio -> libsndfile -> flac
      #     -> graphviz -> gts -> glib
      # Nothing here consumes flac's documentation, so turn it off and drop
      # the two doc tools.
      flac = prev.flac.override { enableDocs = false; };
      # Point every ffmpeg consumer (shairport-sync defaults to the full
      # ffmpeg) at the trimmed headless build described further down.
      # The override flags above only control *external* libraries. ffmpeg
      # still compiles its entire built-in component set - every native
      # decoder, encoder, muxer, demuxer, parser, protocol and filter - which
      # is why libavcodec.so alone is 15.6MB of the lib output.
      #
      # shairport-sync needs exactly two decoders, both native: reading its
      # sources it references only AV_CODEC_ID_AAC and AV_CODEC_ID_ALAC.
      # nixpkgs' ffmpeg exposes no extraConfigureFlags escape hatch, so this
      # is the one place an overrideAttrs is still required. Order matters
      # and works in our favour: appending puts --disable-everything after
      # the generated flag list, clearing the component set, and the
      # --enable-decoder/--enable-parser that follow re-add just what is
      # used. Nothing here touches the libraries themselves (swresample and
      # friends are not "components"), so shairport-sync's linkage is
      # unaffected.
      ffmpeg = (prev.ffmpeg-headless.override ffmpegTrimFlags).overrideAttrs (o: {
        configureFlags = (o.configureFlags or [ ]) ++ [
          "--disable-everything"
          "--enable-decoder=aac,aac_fixed,alac"
          "--enable-parser=aac"
        ];
      });

      # avahi and libpulseaudio each ship optional glib *binding* libraries
      # (libavahi-glib.so, libpulse-mainloop-glib.so) that nothing in this
      # image ever loads, but whose mere existence puts glib - 17MB - into
      # the runtime closure. Checked before removing: `ldd` shows neither
      # avahi-daemon nor shairport-sync with glib in DT_NEEDED, and
      # shairport-sync has no glib store reference at all (glib is one of
      # its buildInputs, but build-time only), so those two binding libs
      # were the only thing keeping glib alive.
      #
      # Both the feature flag and the buildInput are removed: disabling the
      # feature alone would still build glib and can still leak references
      # through generated pkg-config files.
      # Dropping glib also drops dconf (pulseaudio only referenced it by
      # interpolating it into a gsettings wrapper script) and, via the
      # pinned revision's libOnly fix, the 67 daemon modules a library-only
      # build used to ship - which is what referenced fftw.
      avahi = prev.avahi.override { glibSupport = false; };
      libpulseaudio = prev.libpulseaudio.override { glibSupport = false; };
    }
  );

  # --- Runtime-closure trimming (measured; see DOCS.md for before/after) ---
  # shairport-sync depends on ffmpeg for AirPlay 2's AAC decoding, and that
  # one dependency dominates this image: ffmpeg's `lib` output carries a
  # 303MB closure of its own, including video encoders an audio-only
  # AirPlay receiver can never reach (measured on aarch64: x265 12MB,
  # libaom 8MB, libvpx 7MB, svt-av1 5MB, srt 7MB, plus mbedtls 15MB pulled
  # in via srt/rist).
  #
  # Those codecs are dropped below by overriding them off, which cuts about
  # 80MB from the runtime closure. The cost of doing so, measured rather
  # than assumed: the override changes ffmpeg's derivation hash, so it is
  # NOT in cache.nixos.org - verified by querying the override's own output
  # path (404) against plain ffmpeg-headless (200). A device building this
  # with only the default substituters would therefore compile ffmpeg from
  # source, which is exactly what this repo's README warns about. That is
  # why the overridden build is published to this project's own binary
  # cache and the Dockerfile adds that cache as an extra substituter; see
  # the `extra-substituters`/`extra-trusted-public-keys` lines there.
  #
  # Approach deliberately NOT taken: stripping these references off the
  # already-built, cached ffmpeg with removeReferencesTo/nukeReferences.
  # That is normally the right way to shrink a closure without giving up
  # cache hits, but it cannot work here - `patchelf --print-needed
  # libavcodec.so` lists libx265.so.216, libaom.so.3, libvpx.so.12,
  # libSvtAv1Enc.so.4 and libx264.so.165 as real DT_NEEDED entries, so the
  # dynamic loader genuinely needs those files present and removing the
  # references would only make shairport-sync fail to start at runtime.
  # Reference-stripping helps for paths that leak in as strings
  # (pkg-config files, embedded build flags), not for actual dynamic links.
  ffmpegTrimFlags = {
    # nixpkgs' ffmpeg groups its optional-dependency defaults into three
    # tiers - withHeadlessDeps, withSmallDeps, withFullDeps - and nearly
    # every `with*` flag defaults to one of them. ffmpeg-headless is exactly
    # the variant that sets withHeadlessDeps, so turning that one flag off is
    # subtractive in a single move. It takes out:
    #   - the external libraries: x264/x265/vpx/aom/svt-av1/dav1d/theora/webp/
    #     openjpeg/bluray/openmpt/srt/rist/vid.stab (video codecs and
    #     containers an audio-only receiver cannot reach); speex/opus/vorbis/
    #     mp3lame (AirPlay 2 streams AAC and ALAC, whose decoders are native
    #     to ffmpeg - and speex in particular pulled fftw-single, which needs
    #     gfortran, which does not build under musl); gnutls (and with it
    #     p11-kit, unbound and libunistring - AirPlay 2's own crypto is done
    #     by openssl, which stays); lzma/xml2/bzlib; the drawtext/subtitle
    #     stack (ass, fontconfig, freetype, fribidi, harfbuzz, zvbi); v4l2
    #     (which was the last thing dragging in systemd-minimal-libs); alsa
    #     (this app outputs via PulseAudio only); vulkan/vaapi/drm/opencl;
    #     amf and the nvidia encode/decode stack; and cuda-llvm, which was
    #     pulling buildPackages.clang.cc and with it the whole of LLVM, the
    #     largest derivation in this build.
    #   - the non-library feature payload: network, gmp, zimg, iconv, soxr,
    #     zlib, hardcoded tables, pixelutils.
    #   - all four documentation flags (this is where asciidoc entered).
    #   - the ffmpeg/ffprobe/ffplay executables - this app calls the
    #     libraries directly, so skipping them also saves the link step.
    # Only what this app genuinely links is then switched back on below.
    #
    # Stated additively like this, anything nixpkgs later adds to those tiers
    # stays off by default rather than silently reappearing - which an
    # explicit list of ~50 `= false` entries could not promise.
    withHeadlessDeps = false;

    # The libraries shairport-sync actually links, and nothing else.
    # Verified against the built binary rather than assumed: its DT_NEEDED
    # entries name exactly libavcodec.so.63, libavformat.so.63,
    # libavutil.so.61 and libswresample.so.7 - never libavfilter (5.3MB),
    # libswscale (1.3MB) or libavdevice (0.1MB).
    buildAvcodec = true;
    buildAvformat = true;
    buildAvutil = true;
    buildSwresample = true;

    # Switched back on deliberately: withSafeBitstreamReader is a
    # bounds-checking safety feature rather than a feature payload, and this
    # code decodes data arriving off the network.
    withSafeBitstreamReader = true;
  };

  # The generated service `run` scripts are plain non-interactive shell
  # scripts, but `pkgs.bash` is bash-interactive (confirmed by evaluating
  # it: bash-interactive-5.3p15), which drags readline and ncurses along
  # for ~19MB combined. bashNonInteractive is the same bash without them.
  bash = mpkgs.bashNonInteractive;

  # glib is no longer filtered out by hand: at the pinned revision nixpkgs
  # gates shairport-sync's glib on (enableDbus || enableMpris), both false
  # below, so it is simply never an input.
  shairportSync = mpkgs.shairport-sync.override {
    enableAirplay2 = true;
    enableAvahi = true;
    enablePulse = true;
    enableSoxr = true;
    enableMetadata = true;
    enableStdout = true;
    enablePipe = true;
    # WARNING before turning either of these on: nixpkgs' shairport-sync has
    # an unconditional postPatch that rewrites G_BUS_TYPE_SYSTEM to
    # G_BUS_TYPE_SESSION in dbus-service.c and mpris-service.c (4 real
    # occurrences - checked against the source, it is not a no-op). This
    # image runs a *system* bus only - see dbusSystemConf's `<type>system</type>`
    # and /run/dbus/system_bus_socket - and starts nothing that would provide
    # a session bus. So enabling either flag here yields a shairport-sync
    # compiled to look for a session bus that does not exist in this
    # container: it would fail to connect while dbus itself appears healthy.
    # Undo that postPatch as well if these are ever wanted.
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

  # --- Hand-authored configs, adapted from the real upstream templates ---
  # (dbus's bus/system.conf.in and avahi's avahi-daemon/avahi-dbus.conf.in
  # and avahi-daemon/avahi-daemon.conf, fetched from their own repos while
  # writing this - not reconstructed from memory).

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

      <!-- Populated by containerRoot below with avahi's own dbus policy
           snippet (or the fallback one in this file if it can't find one). -->
      <includedir>/etc/dbus-1/system.d</includedir>
    </busconfig>
  '';

  # Fallback avahi dbus policy, used only if the real one can't be located
  # inside the built avahi package at container-root build time.
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
  nssPasswd = mpkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    avahi:x:999:999:Avahi mDNS daemon:/var/empty:/bin/false
  '';

  nssGroup = mpkgs.writeText "group" ''
    root:x:0:
    avahi:x:999:
    netdev:x:1000:
  '';

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
        ${mpkgs.coreutils}/bin/sleep 1
      done
    }
  '';

in
rec {
  inherit shairportSync nqptpPkg;
  # Exposed for introspection/testing (e.g. asserting that the overlay's
  # dbus and ffmpeg really are what every consumer resolves to).
  inherit mpkgs;

  containerRoot =
    mpkgs.runCommand "shairport-sync-container-root"
      {
        nativeBuildInputs = [ mpkgs.findutils ];
      }
      ''
        set -eu

        # --- Discover the real binary/config paths inside the already-built
        # avahi/dbus derivations, rather than guessing bin/ vs sbin/. ---
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

        ln -s "${lib.getExe mpkgs.nqptp}" "$out"/usr/local/bin/nqptp
        ln -s "${lib.getExe shairportSync}" "$out"/usr/local/bin/shairport-sync

        # PID 1: s6-svscan supervising /etc/services.d, restarting anything
        # that exits (its default behavior for any dir it scans - no per-service
        # "type" file needed, unlike the s6-rc layer this deliberately skips).
        ln -s "${mpkgs.s6}/bin/s6-svscan" "$out"/sbin/init

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
        #!${bash}/bin/bash
        set -e
        ${mpkgs.coreutils}/bin/mkdir -p /run/dbus
        ${mpkgs.coreutils}/bin/rm -f /run/dbus/pid
        echo "[dbus] starting"
        exec "@DBUS_DAEMON_BIN@" --config-file=/etc/dbus-1/system.conf --nofork --nopidfile
        RUNEOF
        ${mpkgs.gnused}/bin/sed -i "s|@DBUS_DAEMON_BIN@|$DBUS_DAEMON_BIN|" "$out"/etc/services.d/dbus/run

        # --- avahi (waits for dbus's socket) ---
        cat > "$out"/etc/services.d/avahi/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        ${waitForFn}
        wait_for "dbus system bus" /run/dbus/system_bus_socket
        ${mpkgs.coreutils}/bin/mkdir -p /run/avahi-daemon
        echo "[avahi] starting"
        # No `--no-chroot` (this nixpkgs build of avahi-daemon doesn't
        # accept it - `avahi-daemon --help` doesn't list it) and no `-f`
        # (that flag means "load THIS config file instead", not
        # "foreground" - avahi-daemon already runs in the foreground by
        # default unless told to --daemonize). Both found by actually
        # running this and reading `avahi-daemon --help`, not assumed.
        exec "@AVAHI_DAEMON_BIN@" --no-drop-root --no-rlimits
        RUNEOF
        ${mpkgs.gnused}/bin/sed -i "s|@AVAHI_DAEMON_BIN@|$AVAHI_DAEMON_BIN|" "$out"/etc/services.d/avahi/run

        # --- nqptp (no dependencies - just needs to be up before shairport-sync) ---
        cat > "$out"/etc/services.d/nqptp/run <<'RUNEOF'
        #!${bash}/bin/bash
        set -e
        echo "[nqptp] starting"
        exec ${lib.getExe mpkgs.nqptp}
        RUNEOF

        # --- shairport-sync (waits for avahi, nqptp, and the Supervisor's
        # PulseAudio socket; renders its own config from /data/options.json) ---
        cat > "$out"/etc/services.d/shairport-sync/run <<'RUNEOF'
        #!${bash}/bin/bash
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
