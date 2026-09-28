# syntax=docker/dockerfile:1
# ==============================================================================
# NOTE ON THIS FILE'S ROLE (v3.0.0, pure-Nix architecture)
#
# Almost none of this app's actual logic lives in this Dockerfile anymore.
# What runs, in what order, with what config, and how dbus/avahi/nqptp/
# shairport-sync are wired together is entirely defined in ../nix/default.nix
# as a single derivation, `containerRoot`. This file's only job is:
#   1. build containerRoot inside a Nix builder image,
#   2. copy its full runtime closure (everything it dynamically links
#      against) to /nix in the final image,
#   3. copy containerRoot's own *contents* (not the unpredictable
#      /nix/store/<hash>-... path itself, since that can't be referenced in
#      a Dockerfile COPY written before the build runs) to a fixed path,
#      then COPY that into /.
#
# This means the final image is `FROM scratch` - there is no Alpine, no
# apk, no bashio, no s6-overlay underneath it. PID 1 is Nix-built
# s6-svscan (see nix/default.nix's containerRoot.sbin/init symlink),
# supervising a Nix-generated /etc/services.d tree. The tradeoff the user
# explicitly asked for and accepted: this Dockerfile now looks like a
# generated artifact (because its real content, the container root, IS
# generated, by Nix) rather than a hand-authored one - but it is still
# checked into source control here, byte for byte, like any other file in
# this repo, not written at image-build time by some external script.
#
# WHY `sandbox = false` BELOW:
# Nix's build sandbox needs to unshare mount/user namespaces and set up a
# chroot. Supervisor builds apps with an unprivileged `docker buildx build`
# (confirmed by reading the exact command Supervisor logs when installing
# this app - no `--privileged`, no extra capabilities), where that setup
# is not permitted, so leaving the sandbox on makes the build fail in the
# one environment this Dockerfile actually has to work in.
#
# This is a constraint of *building inside Docker*, NOT a property of
# nix/default.nix: the same `containerRoot` derivation was built natively
# on an aarch64 NixOS host with `sandbox = true` (NixOS's default) and
# succeeded, producing an identical 145-path / 343 MB runtime closure. So
# the expression is sandbox-clean; only the container environment isn't.
# The cost of disabling it is that builders here can see the host FS and
# network, so Nix cannot *enforce* purity - it is enforced in practice by
# the pinned NIXPKGS_REV plus the fact that essentially everything comes
# prebuilt from cache.nixos.org.
#
# WHY NOT pkgsStatic (and the musl question):
# pkgsStatic was originally wanted here for the obvious reason - dropping
# the glibc-based runtime closure would make this image much smaller.
# The reason recorded for abandoning it was "something depends on NSS".
# That reason does NOT survive checking, and is worth writing down
# accurately so nobody re-derives the wrong conclusion:
#   - What this image actually needs is getpwnam/getgrnam for the
#     root/avahi users and netdev group that dbus's and avahi's own policy
#     files name (see nix/default.nix's NSS notes - missing /etc/passwd was
#     one of the 3.0.0 bugs). It does NOT need pluggable NSS modules;
#     nss-mdns is deliberately absent (see DOCS.md).
#   - pkgsStatic is musl, and musl has no NSS mechanism at all - its
#     getpwnam/getgrnam parse /etc/passwd and /etc/group directly, which
#     is exactly the lookup this image performs. Confirmed that musl's
#     libc.so exports getpwnam/getgrnam.
# So the real objections are different ones:
#   1. Nothing in a musl-based build of this stack is in cache.nixos.org -
#      checked: pkgsMusl.dbus, pkgsMusl.avahi and pkgsMusl.shairport-sync
#      all 404 there - so the entire stack would compile from source.
#   2. Static specifically is also the wrong shape here: this image runs
#      four separate daemons (dbus, avahi, nqptp, shairport-sync), so
#      static linking duplicates their shared dependencies into each
#      executable. Dynamically-linked pkgsMusl would very likely be
#      smaller than pkgsStatic for that reason (musl's own closure is 4MB
#      against glibc's 47MB).
# Neither objection is fatal, so this remains a live option rather than a
# closed decision; it is simply a much larger change than the trimming
# already done, and it trades away every public cache hit.
#
# (Earlier versions of this file claimed both rationales were documented
# in nix/default.nix and the README/DOCS.md. They were not - the README
# pointed back here and neither explained either decision. Written down
# properly here now, at the line it actually applies to.)
# ==============================================================================
FROM nixos/nix:2.35.2 AS builder

# Pinned in nix/default.nix's own default argument too; passed explicitly
# here so both stay traceably in sync with a single source (this ARG).
# TEMPORARY: this revision currently exists only on a fork; GitHub serves
# fork-network commits from the upstream archive URL (allow a short
# propagation delay after pushing). See nix/default.nix for the options.
ARG NIXPKGS_REV=8894653cb54b428b9b953b3418496c8cf1f53330

# Binary cache holding the overridden, codec-trimmed ffmpeg from
# nix/default.nix. That override is deliberately not in cache.nixos.org
# (changing ffmpeg's arguments changes its derivation hash), so WITHOUT a
# substituter that has it, every single install compiles ffmpeg from
# source - including running its test suite. With it, the whole closure is
# a ~37MB download. cache.nixos.org is still consulted for everything
# else; these are *extra* substituters, not a replacement.
#
# TEMPORARY/TEST VALUES: this currently points at a throwaway local cache
# used to validate the mechanism end to end against a real Supervisor.
# Replace both with the project's real cache before publishing.
ARG NIX_CACHE_URL=http://10.0.2.2:8899
ARG NIX_CACHE_PUBKEY=shairport-test-cache:Y/xXjBgKsh7Op4543lbXK8dL+1AfK/WNc/iP/LKApm8=

RUN mkdir -p /etc/nix \
    && { \
        echo "sandbox = false"; \
        echo "experimental-features = nix-command"; \
        echo "extra-substituters = ${NIX_CACHE_URL}"; \
        echo "extra-trusted-public-keys = ${NIX_CACHE_PUBKEY}"; \
        echo "fallback = true"; \
    } >> /etc/nix/nix.conf
# `fallback = true` above: if the extra cache is unreachable, build from
# source instead of failing the install outright.

COPY nix/default.nix /build/default.nix

RUN set -eux; \
    OUT="$(nix-build --no-out-link \
        --argstr nixpkgsRev "${NIXPKGS_REV}" \
        -A containerRoot \
        /build/default.nix)"; \
    echo "$OUT" > /output-path; \
    mkdir -p /output/rootfs-overlay; \
    # Copy the DEREFERENCED contents of containerRoot to a fixed path (not
    # the store path itself, which the final stage's Dockerfile text can't
    # know in advance) - this is what the final stage's COPY reads from.
    cp -rL "$OUT"/. /output/rootfs-overlay/; \
    # Copy the full transitive runtime closure (containerRoot itself, plus
    # every store path it references - glibc, avahi, dbus, shairport-sync,
    # its ffmpeg/openssl/soxr inputs, s6, bash, jq, gnused, etc.) so the
    # dynamic linker and any exec'd interpreter paths resolve at runtime
    # in the scratch image exactly as they did during the build.
    mkdir -p /output/nix/store; \
    nix-store -qR "$OUT" \
        | xargs -I{} cp -a --parents {} /output/

# ==============================================================================
# Final stage: no base image at all - the entire filesystem is what Nix
# built above. No apk, no musl libc, no bashio, no s6-overlay.
# ==============================================================================
FROM scratch

COPY --from=builder /output/nix /nix
COPY --from=builder /output/rootfs-overlay/ /

# s6-svscan takes its scan directory as an explicit argument - it does not
# default to one - confirmed by actually running this image, which
# otherwise exits immediately with "usage: s6-svscan ... scandir".
ENTRYPOINT ["/sbin/init", "/etc/services.d"]
