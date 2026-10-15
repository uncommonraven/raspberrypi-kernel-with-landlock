#!/usr/bin/env bash
# Build one target: fetch the pinned kernel source, merge the Landlock config
# fragment, assert the resulting .config, then build Image and modules.
#
# Usage: scripts/build.sh <defconfig> <image-name> <out-dir> <localversion>
#   defconfig     defconfig name, e.g. bcm2712_defconfig
#   image-name    kernel image name in the release, e.g. kernel_2712.img
#   out-dir       build output directory, relative to the repo root,
#                 e.g. build/bcm2712
#   localversion  CONFIG_LOCALVERSION for this target, e.g. -v8-16k
set -euo pipefail

die() {
  echo "build: $*" >&2
  exit 1
}

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <defconfig> <image-name> <out-dir> <localversion>" >&2
  exit 2
fi
defconfig=$1
image_name=$2
out_arg=$3
localversion=$4
case $localversion in
  *-landlock) ;;
  *) die "localversion must end in -landlock (e.g. -v8-16k-landlock): $localversion" ;;
esac

case $defconfig in
  bcm2712_defconfig)
    baseline_package=linux-image-rpi-2712
    devices=("Raspberry Pi 5" "Raspberry Pi 500" "Raspberry Pi 500+" "Compute Module 5")
    ;;
  *) die "no config baseline package for $defconfig" ;;
esac

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
out_dir=$(realpath -m "$out_arg")

# shellcheck source=../kernel/pins.env
. "$repo_root/kernel/pins.env"

command -v aarch64-linux-gnu-gcc >/dev/null || die "aarch64-linux-gnu-gcc not found"

# One source checkout per pinned SHA, shared by all targets.
src_dir="$repo_root/build/src"
head=""
if [ -d "$src_dir/.git" ]; then
  head=$(git -C "$src_dir" rev-parse -q --verify HEAD 2>/dev/null || true)
fi
if [ "$head" != "$RPI_KERNEL_SHA" ]; then
  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  git -C "$src_dir" init -q
  git -C "$src_dir" remote add origin "$RPI_KERNEL_REPO"
  git -C "$src_dir" fetch -q --depth=1 origin "$RPI_KERNEL_SHA"
  git -C "$src_dir" checkout -q FETCH_HEAD
fi
cd "$src_dir"

# LOCALVERSION= (set, but empty) stops setlocalversion appending "+" to the
# release string; CONFIG_LOCALVERSION supplies the target suffix instead.
kmake() {
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= O="$out_dir" "$@"
}

kmake "$defconfig"
scripts/config --file "$out_dir/.config" --set-str LOCALVERSION "$localversion"
scripts/kconfig/merge_config.sh -O "$out_dir" -m "$out_dir/.config" \
  "$repo_root/kernel/config/landlock.config"
kmake olddefconfig

config="$out_dir/.config"
require_line() {
  grep -qxF "$1" "$config" || die "$config does not contain: $1"
}

require_line "CONFIG_SECURITY_APPARMOR=y"
require_line "CONFIG_LOCALVERSION=\"$localversion\""

# The config baseline diff (T06) runs here, after olddefconfig and before the
# build, so that it describes the .config that is shipped.
kernel_version=$(kmake -s kernelversion)
"$repo_root/scripts/fetch-baseline.sh" "$baseline_package" "$kernel_version" "$out_dir/baseline"
config_diff="$out_dir/config-$(basename "$out_dir").diff"
"$repo_root/scripts/check-config-diff.sh" "$out_dir/baseline/baseline.config" "$config" \
  "$config_diff"

kmake -j"$(nproc)" Image modules dtbs
cp "$out_dir/arch/arm64/boot/Image" "$out_dir/$image_name"

release=$(kmake -s kernelrelease)
staging="$out_dir/modules-staging"
rm -rf "$staging"
kmake INSTALL_MOD_PATH="$staging" modules_install
# Host-specific symlinks (e.g. build -> this checkout) would dangle on the device.
find "$staging/lib/modules/$release" -maxdepth 1 -type l -delete
tar -C "$staging/lib/modules/$release" --sort=name --owner=0 --group=0 --numeric-owner \
  -czf "$out_dir/modules.tar.gz" .

release_dir="$out_dir/release"
rm -rf "$release_dir"
mkdir -p "$release_dir"
cp "$out_dir/$image_name" "$out_dir/modules.tar.gz" "$config" \
  "$repo_root/kernel/config/landlock.config" "$repo_root/kernel/pins.env" \
  "$config_diff" "$release_dir/"

# Last: the manifest records the hashes of every file staged above.
"$repo_root/scripts/write-manifest.sh" "$release_dir" "$image_name" "$defconfig" \
  "$localversion" "$out_dir/baseline/baseline.provenance" "${devices[@]}"

echo "build: $image_name, modules.tar.gz and manifest.json (kernel $release) staged in $release_dir"
