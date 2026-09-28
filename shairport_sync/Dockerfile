# syntax=docker/dockerfile:1
#
# Everything this app does is defined in nix/default.nix as a single
# derivation, `containerRoot`. This file builds it, copies its runtime closure
# to /nix, and copies its contents onto / in a FROM scratch image. PID 1 is
# Nix-built s6-svscan.
#
# sandbox = false because Nix's sandbox needs to unshare mount/user namespaces,
# which Supervisor's unprivileged `docker buildx build` does not permit. The
# same derivation builds with the sandbox on outside Docker, so purity here
# rests on the pinned NIXPKGS_REV instead.
FROM nixos/nix:2.35.2 AS builder

# Also nix/default.nix's default; passed explicitly so both stay in sync.
ARG NIXPKGS_REV=16b0cbc9754e848a4ea46fccb9b511b7d0c9622b

# None of this musl stack is in cache.nixos.org, so without these the install
# compiles dbus, avahi, libpulseaudio, ffmpeg and shairport-sync from source.
# With them the whole closure is a 9.8MiB download. cache.nixos.org is still
# consulted; fallback = true degrades an unreachable cache to a slow build
# rather than a failed install.
#
# TEMPORARY/TEST VALUES: replace both before publishing.
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

COPY nix/default.nix /build/default.nix

RUN set -eux; \
    OUT="$(nix-build --no-out-link \
        --argstr nixpkgsRev "${NIXPKGS_REV}" \
        -A containerRoot \
        /build/default.nix)"; \
    echo "$OUT" > /output-path; \
    mkdir -p /output/rootfs-overlay; \
    cp -rL "$OUT"/. /output/rootfs-overlay/; \
    mkdir -p /output/nix/store; \
    nix-store -qR "$OUT" \
        | xargs -I{} cp -a --parents {} /output/

FROM scratch

COPY --from=builder /output/nix /nix
COPY --from=builder /output/rootfs-overlay/ /

ENTRYPOINT ["/sbin/init", "/etc/services.d"]
