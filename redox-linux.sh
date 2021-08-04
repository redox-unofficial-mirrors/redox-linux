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

if [ ! -d relibc/sysroot ]
then
    make -C relibc sysroot
fi

mkdir -p toolchain

if [ ! -f toolchain/relibc.pkgar ]
then
    pkgar create "relibc/sysroot" --archive toolchain/relibc.pkgar --skey "${PKGAR_SKEY}"
fi

## Binutils

if [ ! -f toolchain/binutils.tar.bz2 ]
then
    wget -O toolchain/binutils.tar.bz2.partial "https://gitlab.redox-os.org/redox-os/binutils-gdb/-/archive/redox/binutils-gdb-redox.tar.bz2"
    mv toolchain/binutils.tar.bz2.partial toolchain/binutils.tar.bz2
fi

if [ ! -d toolchain/binutils ]
then
    rm -rf toolchain/binutils.partial
    mkdir -p toolchain/binutils.partial
    tar --extract --file toolchain/binutils.tar.bz2 --directory toolchain/binutils.partial --strip-components=1
    pushd toolchain/binutils.partial
        patch -p1 < ../../binutils.patch
    popd
    mv toolchain/binutils.partial toolchain/binutils
fi

if [ ! -d toolchain/binutils-build ]
then
    rm -rf toolchain/binutils-build.partial
    mkdir -p toolchain/binutils-build.partial
    pushd toolchain/binutils-build.partial
        ../binutils/configure \
            --target="x86_64-unknown-linux-relibc" \
            --program-prefix="x86_64-unknown-linux-relibc-" \
            --prefix="" \
            --disable-werror
        make -j "$(nproc)" all
    popd
    mv toolchain/binutils-build.partial toolchain/binutils-build
fi

if [ ! -d toolchain/binutils-install ]
then
    rm -rf toolchain/binutils-install.partial
    mkdir -p toolchain/binutils-install.partial
    pushd toolchain/binutils-build
        make -j "$(nproc)" install DESTDIR="$(realpath ../binutils-install.partial)"
    popd
    mv toolchain/binutils-install.partial toolchain/binutils-install
fi

if [ ! -f toolchain/binutils.pkgar ]
then
    pkgar create toolchain/binutils-install --archive toolchain/binutils.pkgar --skey "${PKGAR_SKEY}"
fi

export PATH="${PWD}/toolchain/binutils-install/bin:${PATH}"

## GCC

if [ ! -f toolchain/gcc.tar.bz2 ]
then
    wget -O toolchain/gcc.tar.bz2.partial "https://gitlab.redox-os.org/redox-os/gcc/-/archive/redox/gcc-redox.tar.bz2"
    mv toolchain/gcc.tar.bz2.partial toolchain/gcc.tar.bz2
fi

if [ ! -d toolchain/gcc ]
then
    rm -rf toolchain/gcc.partial
    mkdir -p toolchain/gcc.partial
    tar --extract --file toolchain/gcc.tar.bz2 --directory toolchain/gcc.partial --strip-components=1
    pushd toolchain/gcc.partial
        patch -p1 < ../../gcc.patch
        ./contrib/download_prerequisites
    popd
    mv toolchain/gcc.partial toolchain/gcc
fi

### GCC Freestanding

if [ ! -d toolchain/gcc-freestanding-build ]
then
    rm -rf toolchain/gcc-freestanding-build.partial
    mkdir -p toolchain/gcc-freestanding-build.partial
    pushd toolchain/gcc-freestanding-build.partial
        ../gcc/configure \
            --target="x86_64-unknown-linux-relibc" \
            --program-prefix="x86_64-unknown-linux-relibc-" \
            --prefix="" \
            --disable-bootstrap \
            --disable-nls \
            --enable-languages=c,c++ \
            --without-headers
        make -j "$(nproc)" all-gcc
    popd
    mv toolchain/gcc-freestanding-build.partial toolchain/gcc-freestanding-build
fi

if [ ! -d toolchain/gcc-freestanding-install ]
then
    rm -rf toolchain/gcc-freestanding-install.partial
    mkdir -p toolchain/gcc-freestanding-install.partial
    pushd toolchain/gcc-freestanding-build
        make -j "$(nproc)" install-gcc DESTDIR="$(realpath ../gcc-freestanding-install.partial)"
    popd
    mv toolchain/gcc-freestanding-install.partial toolchain/gcc-freestanding-install
fi

if [ ! -f toolchain/gcc-freestanding.pkgar ]
then
    pkgar create toolchain/gcc-freestanding-install --archive toolchain/gcc-freestanding.pkgar --skey "${PKGAR_SKEY}"
fi

### GCC Hosted

if [ ! -d toolchain/gcc-build-sysroot ]
then
    rm -rf toolchain/gcc-build-sysroot.partial
    mkdir -p toolchain/gcc-build-sysroot.partial
    for pkg in binutils gcc-freestanding relibc
    do
        pkgar extract toolchain/gcc-build-sysroot.partial --archive "toolchain/${pkg}.pkgar" --pkey "${PKGAR_PKEY}"
    done
    mv toolchain/gcc-build-sysroot.partial toolchain/gcc-build-sysroot
fi

GCC_BUILD_SYSROOT="$(realpath toolchain/gcc-build-sysroot)"

if [ ! -d toolchain/gcc-build ]
then
    rm -rf toolchain/gcc-build.partial
    mkdir -p toolchain/gcc-build.partial
    pushd toolchain/gcc-build.partial
        env PATH="${GCC_BUILD_SYSROOT}/bin:${PATH}" \
        ../gcc/configure \
            --target="x86_64-unknown-linux-relibc" \
            --program-prefix="x86_64-unknown-linux-relibc-" \
            --prefix="" \
            --with-sysroot \
            --with-build-sysroot="${GCC_BUILD_SYSROOT}" \
            --with-native-system-header-dir="/include" \
            --disable-bootstrap \
            --disable-libgomp \
            --disable-multilib \
            --disable-nls \
            --disable-werror \
            --enable-languages=c,c++ \
            --enable-shared \
            --enable-static \
            --enable-threads=posix \
            && \
        make -j "$(nproc)" all-gcc all-target-libgcc
        #all-target-libstdc++-v3
    popd
    mv toolchain/gcc-build.partial toolchain/gcc-build
fi

if [ ! -d toolchain/gcc-install ]
then
    rm -rf toolchain/gcc-install.partial
    mkdir -p toolchain/gcc-install.partial
    pushd toolchain/gcc-build
        env PATH="${GCC_BUILD_SYSROOT}/bin:${PATH}" \
        make -j "$(nproc)" DESTDIR="$(realpath ../gcc-install.partial)" install-gcc install-target-libgcc
        #install-target-libstdc++-v3
    popd
    mv toolchain/gcc-install.partial toolchain/gcc-install
fi

if [ ! -f toolchain/gcc.pkgar ]
then
    pkgar create toolchain/gcc-install --archive toolchain/gcc.pkgar --skey "${PKGAR_SKEY}"
fi

if [ ! -d toolchain/sysroot ]
then
    rm -rf toolchain/sysroot.partial
    mkdir -p toolchain/sysroot.partial
    for pkg in binutils gcc relibc
    do
        pkgar extract toolchain/sysroot.partial --archive "toolchain/${pkg}.pkgar" --pkey "${PKGAR_PKEY}"
    done
    mv toolchain/sysroot.partial toolchain/sysroot
fi

export PATH="${PWD}/toolchain/sysroot/bin:${PATH}"

## Packages

mkdir -p pkg

function cargo-install {
    docker run --rm -it -v "${PWD}":/home/rust/src ekidd/rust-musl-builder \
    cargo install "$@"
}

function pkgar-cargo-install {
    name="$1"
    shift

    if [ ! -f "pkg/${name}.pkgar" ]
    then
        rm -rf "pkg/${name}.partial"
        mkdir -p "pkg/${name}.partial"
        cargo-install --root "pkg/${name}.partial" "$@"
        pkgar create "pkg/${name}.partial" --archive "pkg/${name}.pkgar.partial" --skey "${PKGAR_SKEY}"
        rm -rf "pkg/${name}.partial"
        mv "pkg/${name}.pkgar.partial" "pkg/${name}.pkgar"
    fi
}

pkgar-cargo-install findutils --git https://github.com/uutils/findutils.git findutils
pkgar-cargo-install ion --git https://gitlab.redox-os.org/redox-os/ion.git ion-shell

if [ ! -f pkg/uutils.pkgar ]
then
    rm -rf pkg/uutils.partial
    mkdir -p pkg/uutils.partial
    musl-cargo-install --root pkg/uutils.partial --git https://github.com/uutils/coreutils coreutils
    pkg/uutils.partial/bin/coreutils | tail -n +7 | tr -d ' ' | tr -d '\n' | tr ',' '\n' | while read bin
    do
        ln -fs coreutils pkg/uutils.partial/bin/"${bin}"
    done
    pkgar create pkg/uutils.partial --archive pkg/uutils.pkgar --skey "${PKGAR_SKEY}"
    rm -rf pkg/uutils.partial
fi

chroot_create sysroot

set +e
chroot_unmount sysroot
set -e

rm -rf sysroot/{bin,include,lib}
mkdir -p sysroot/{bin,include,lib}

for pkg in findutils ion uutils
do
    pkgar extract sysroot --archive "pkg/${pkg}.pkgar" --pkey "${PKGAR_PKEY}"
done

chroot_mount sysroot

set +e

sudo chroot sysroot /bin/ion

chroot_unmount sysroot
