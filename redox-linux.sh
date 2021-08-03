#!/usr/bin/env bash

set -ex

CHROOT_MOUNTS=(dev proc sys)

function chroot_create {
    for mount in "${CHROOT_MOUNTS[@]}"
    do
        mkdir -p "$1/${mount}"
    done
}

function chroot_unmount {
    for mount in "${CHROOT_MOUNTS[@]}"
    do
        sudo umount "$1/${mount}" || sudo umount --lazy "$1/${mount}"
    done
}

function chroot_mount {
    for mount in "${CHROOT_MOUNTS[@]}"
    do
        sudo mount --bind "/${mount}" "$1/${mount}"
    done
}

mkdir -p prefix/{bin,keys}

if [ ! -x prefix/bin/pkgar ]
then
    cargo install --root prefix --path pkgar/pkgar
fi

if [ ! -x prefix/bin/pkgar-keys ]
then
    cargo install --root prefix --path pkgar/pkgar-keys
fi

export PATH="${PWD}/prefix/bin:${PATH}"

PKGAR_SKEY="prefix/keys/id_ed25519.toml"
PKGAR_PKEY="prefix/keys/id_ed25519.pub.toml"

if [ ! -f "${PKGAR_SKEY}" -o ! -f "${PKGAR_PKEY}" ]
then
    pkgar-keys gen --force --plaintext --skey "${PKGAR_SKEY}" --pkey "${PKGAR_PKEY}"
fi

function musl-cargo-install {
    docker run --rm -it -v "${PWD}":/home/rust/src ekidd/rust-musl-builder \
    cargo install "$@"
}

function pkgar-cargo-install {
    name="$1"
    shift

    if [ ! -f "pkg/${name}.pkgar" ]
    then
        rm -rf "pkg/${name}.tmp"
        mkdir -p "pkg/${name}.tmp"
        musl-cargo-install --root "pkg/${name}.tmp" "$@"
        pkgar create "pkg/${name}.tmp" --archive "pkg/${name}.pkgar.tmp" --skey "${PKGAR_SKEY}"
        rm -rf "pkg/${name}.tmp"
        mv "pkg/${name}.pkgar.tmp" "pkg/${name}.pkgar"
    fi
}

if [ ! -f pkg/relibc.pkgar ]
then
    make -C relibc sysroot
    pkgar create relibc/sysroot --archive pkg/relibc.pkgar --skey "${PKGAR_SKEY}"
fi

pkgar-cargo-install findutils --git https://github.com/uutils/findutils.git findutils
pkgar-cargo-install ion --git https://gitlab.redox-os.org/redox-os/ion.git ion-shell

if [ ! -f pkg/uutils.pkgar ]
then
    rm -rf pkg/uutils.tmp
    mkdir -p pkg/uutils.tmp
    musl-cargo-install --root pkg/uutils.tmp --git https://github.com/uutils/coreutils coreutils
    pkg/uutils.tmp/bin/coreutils | tail -n +7 | tr -d ' ' | tr -d '\n' | tr ',' '\n' | while read bin
    do
        ln -fs coreutils pkg/uutils.tmp/bin/"${bin}"
    done
    pkgar create pkg/uutils.tmp --archive pkg/uutils.pkgar --skey "${PKGAR_SKEY}"
    rm -rf pkg/uutils.tmp
fi

chroot_create sysroot

set +e
chroot_unmount sysroot
set -e

rm -rf sysroot/{bin,include,lib}
mkdir -p sysroot/{bin,include,lib}

for pkg in findutils ion relibc uutils
do
    pkgar extract sysroot --archive "pkg/${pkg}.pkgar" --pkey "${PKGAR_PKEY}"
done

chroot_mount sysroot

set +e

sudo chroot sysroot /bin/ion

chroot_unmount sysroot
