#!/usr/bin/env bash
# Extract the config Raspberry Pi ships for one pinned kernel release.
#
# Usage: scripts/fetch-baseline.sh <package> <kernel-version> <work-dir>
#   package         metapackage name, e.g. linux-image-rpi-2712
#   kernel-version  upstream version from the pinned Makefile, e.g. 6.18.50
#   work-dir        receives baseline.config and baseline.provenance
#
# Only the release matching kernel-version is accepted. There is no fallback
# to another version, because a wrong baseline makes the diff meaningless.
set -euo pipefail

APT_BASE=https://archive.raspberrypi.com/debian
APT_SUITE=trixie
APT_COMPONENT=main
APT_ARCH=arm64

die() {
  echo "fetch-baseline: $*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <package> <kernel-version> <work-dir>" >&2
  exit 2
fi
package=$1
kernel_version=$2
work_dir=$3

mkdir -p "$work_dir"
work_dir=$(realpath "$work_dir")
index="$work_dir/Packages"
curl -fsSL "$APT_BASE/dists/$APT_SUITE/$APT_COMPONENT/binary-$APT_ARCH/Packages.gz" | gzip -dc > "$index"

# Prints "Version<TAB>Filename<TAB>SHA256<TAB>Depends" for each stanza of
# package $1 whose upstream version (epoch stripped) is $2.
select_stanzas() {
  awk -v pkg="$1" -v kver="$2" '
    BEGIN { RS = ""; FS = "\n"; OFS = "\t" }
    {
      name = ""; ver = ""; fn = ""; sha = ""; dep = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) name = substr($i, 10)
        else if ($i ~ /^Version: /) ver = substr($i, 10)
        else if ($i ~ /^Filename: /) fn = substr($i, 11)
        else if ($i ~ /^SHA256: /) sha = substr($i, 9)
        else if ($i ~ /^Depends: /) dep = substr($i, 10)
      }
      up = ver
      sub(/^[0-9]+:/, "", up)
      if (name == pkg && substr(up, 1, length(kver) + 1) == kver "-")
        print ver, fn, sha, dep
    }' "$index"
}

meta=$(select_stanzas "$package" "$kernel_version")
[ -n "$meta" ] || die "no $package $kernel_version-* in $APT_SUITE; refusing to fall back to another version"
[ "$(printf '%s\n' "$meta" | wc -l)" -eq 1 ] || die "several $package $kernel_version-* entries; refusing to guess:
$meta"

IFS=$'\t' read -r meta_version _ _ meta_depends <<< "$meta"

# The metapackage holds no files; it depends on the versioned image package.
image_suffix=${package#linux-image-}
image_pkg=$(printf '%s\n' "$meta_depends" | tr ',' '\n' | sed 's/^ *//; s/ .*//' \
  | grep -E "^linux-image-[0-9].*-${image_suffix}$" || true)
[ -n "$image_pkg" ] || die "$package does not depend on a versioned linux-image package"
[ "$(printf '%s\n' "$image_pkg" | wc -l)" -eq 1 ] || die "several image packages in $package dependencies: $image_pkg"

image=$(select_stanzas "$image_pkg" "$kernel_version")
[ -n "$image" ] || die "$image_pkg is not in $APT_SUITE"
IFS=$'\t' read -r image_version image_filename image_sha _ <<< "$image"
[ "$image_version" = "$meta_version" ] || die "$image_pkg is $image_version, expected $meta_version"

deb="$work_dir/$(basename "$image_filename")"
curl -fsSL -o "$deb" "$APT_BASE/$image_filename"
actual_sha=$(sha256sum "$deb" | cut -d' ' -f1)
[ "$actual_sha" = "$image_sha" ] || die "SHA-256 of $deb is $actual_sha, index says $image_sha"

extract="$work_dir/extract"
rm -rf "$extract"
mkdir -p "$extract"
(cd "$extract" && ar x "$deb")
tar -xf "$extract"/data.tar.* -C "$extract" --wildcards '*boot/config-*'

configs=$(find "$extract/boot" -maxdepth 1 -type f -name 'config-*' 2>/dev/null || true)
[ -n "$configs" ] || die "$image_pkg contains no boot/config-*"
[ "$(printf '%s\n' "$configs" | wc -l)" -eq 1 ] || die "$image_pkg contains several boot/config-* files"
config_name=$(basename "$configs")
case $config_name in
  config-"$kernel_version"[+-]*) ;;
  *) die "$config_name does not match kernel $kernel_version" ;;
esac

baseline="$work_dir/baseline.config"
cp "$configs" "$baseline"

grep -qx 'CONFIG_LSM=""' "$baseline" || die "baseline does not have CONFIG_LSM=\"\""
grep -q '^CONFIG_SECURITY_LANDLOCK=' "$baseline" && die "baseline already enables CONFIG_SECURITY_LANDLOCK"
grep -qx 'CONFIG_SECURITY_APPARMOR=y' "$baseline" || die "baseline does not have CONFIG_SECURITY_APPARMOR=y"

config_sha=$(sha256sum "$baseline" | cut -d' ' -f1)
cat > "$work_dir/baseline.provenance" <<EOF
BASELINE_SUITE=$APT_SUITE
BASELINE_METAPACKAGE=$package
BASELINE_PACKAGE=$image_pkg
BASELINE_VERSION=$image_version
BASELINE_DEB_URL=$APT_BASE/$image_filename
BASELINE_DEB_SHA256=$image_sha
BASELINE_CONFIG_NAME=$config_name
BASELINE_CONFIG_SHA256=$config_sha
EOF

echo "fetch-baseline: $image_pkg $image_version -> $baseline"
