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
# Why Nix's build sandbox is disabled and why pkgsStatic is avoided: see
# nix/default.nix's own header comment and this repo's README/DOCS.md -
# those decisions are unchanged from v2.0.0 and are documented once, at
# the source of truth, rather than duplicated here.
# ==============================================================================
FROM nixos/nix:2.35.2 AS builder

# Pinned in nix/default.nix's own default argument too; passed explicitly
# here so both stay traceably in sync with a single source (this ARG).
ARG NIXPKGS_REV=55d33a38f82193676603b4b58572b8718d6623b7

RUN mkdir -p /etc/nix \
    && { \
        echo "sandbox = false"; \
        echo "experimental-features = nix-command"; \
    } >> /etc/nix/nix.conf

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
