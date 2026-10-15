#!/usr/bin/env bash
# Write manifest.json for one target. Run it after every other file in the
# release directory is final: the manifest records their SHA-256 hashes.
#
# Usage: scripts/write-manifest.sh <release-dir> <image-name> <defconfig> <localversion> <baseline-provenance> <device>...
#   release-dir          staging directory with the files to publish
#   image-name           kernel image name in the release, e.g. kernel_2712.img
#   defconfig            defconfig name, e.g. bcm2712_defconfig
#   localversion         CONFIG_LOCALVERSION for this target, e.g. -v8-16k-landlock
#   baseline-provenance  baseline.provenance written by scripts/fetch-baseline.sh
#   device               a device the image is for; repeat for each device
set -euo pipefail

die() {
  echo "write-manifest: $*" >&2
  exit 1
}

if [ "$#" -lt 6 ]; then
  echo "usage: $0 <release-dir> <image-name> <defconfig> <localversion> <baseline-provenance> <device>..." >&2
  exit 2
fi
release_dir=$(realpath "$1")
image_name=$2
defconfig=$3
localversion=$4
provenance=$5
shift 5
devices=("$@")

# The values are written into JSON without escaping, so refuse anything that
# would need it.
jstr() {
  case $1 in
    *[\"\\]* | *[[:cntrl:]]*) die "refusing to write '$1' into JSON" ;;
  esac
  printf '"%s"' "$1"
}

staged=("$image_name" modules.tar.gz .config landlock.config pins.env)
for f in "${staged[@]}"; do
  [ -f "$release_dir/$f" ] || die "$release_dir is missing $f"
done
shopt -s nullglob
diffs=("$release_dir"/config-*.diff)
shopt -u nullglob
[ "${#diffs[@]}" -eq 1 ] || die "expected one config-*.diff in $release_dir, found ${#diffs[@]}"
staged+=("$(basename "${diffs[0]}")")

# shellcheck source=/dev/null
. "$release_dir/pins.env"
for var in RPI_KERNEL_REPO RPI_KERNEL_TAG RPI_KERNEL_SHA; do
  [ -n "${!var:-}" ] || die "pins.env does not set $var"
done

grep -qxF "CONFIG_LOCALVERSION=\"$localversion\"" "$release_dir/.config" \
  || die ".config does not set CONFIG_LOCALVERSION=\"$localversion\""

[ -f "$provenance" ] || die "$provenance not found"
# shellcheck source=/dev/null
. "$provenance"
for var in BASELINE_SUITE BASELINE_METAPACKAGE BASELINE_PACKAGE BASELINE_VERSION \
  BASELINE_DEB_URL BASELINE_DEB_SHA256 BASELINE_CONFIG_NAME BASELINE_CONFIG_SHA256; do
  [ -n "${!var:-}" ] || die "$provenance does not set $var"
done

# vermagic comes from the modules as they ship, not from the source tree, and
# every module must agree on it.
modules_tmp=$(mktemp -d)
trap 'rm -rf "$modules_tmp"' EXIT
tar -xzf "$release_dir/modules.tar.gz" -C "$modules_tmp"
vermagics=$(find "$modules_tmp" -type f -name '*.ko*' -exec modinfo -F vermagic {} + | sort -u) \
  || die "modinfo failed on the modules in modules.tar.gz"
[ "$(printf '%s\n' "$vermagics" | grep -c .)" -eq 1 ] \
  || die "modules.tar.gz has no module, or several vermagic values: $vermagics"
vermagic=$vermagics
case ${vermagic%% *} in
  *"$localversion") ;;
  *) die "vermagic '$vermagic' does not end with LOCALVERSION $localversion" ;;
esac

q_image=$(jstr "$image_name")
q_defconfig=$(jstr "$defconfig")
q_localversion=$(jstr "$localversion")
q_vermagic=$(jstr "$vermagic")
q_repo=$(jstr "$RPI_KERNEL_REPO")
q_tag=$(jstr "$RPI_KERNEL_TAG")
q_sha=$(jstr "$RPI_KERNEL_SHA")
q_suite=$(jstr "$BASELINE_SUITE")
q_metapackage=$(jstr "$BASELINE_METAPACKAGE")
q_package=$(jstr "$BASELINE_PACKAGE")
q_version=$(jstr "$BASELINE_VERSION")
q_deb_url=$(jstr "$BASELINE_DEB_URL")
q_deb_sha=$(jstr "$BASELINE_DEB_SHA256")
q_config_name=$(jstr "$BASELINE_CONFIG_NAME")
q_config_sha=$(jstr "$BASELINE_CONFIG_SHA256")

device_json=""
for device in "${devices[@]}"; do
  q=$(jstr "$device")
  device_json+="${device_json:+, }$q"
done

manifest="$release_dir/manifest.json"
{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "image_name": %s,\n' "$q_image"
  printf '  "defconfig": %s,\n' "$q_defconfig"
  printf '  "devices": [%s],\n' "$device_json"
  printf '  "source": {"repo": %s, "tag": %s, "sha": %s},\n' "$q_repo" "$q_tag" "$q_sha"
  printf '  "localversion": %s,\n' "$q_localversion"
  printf '  "vermagic": %s,\n' "$q_vermagic"
  printf '  "baseline": {\n'
  printf '    "suite": %s,\n' "$q_suite"
  printf '    "metapackage": %s,\n' "$q_metapackage"
  printf '    "package": %s,\n' "$q_package"
  printf '    "version": %s,\n' "$q_version"
  printf '    "deb_url": %s,\n' "$q_deb_url"
  printf '    "deb_sha256": %s,\n' "$q_deb_sha"
  printf '    "config_name": %s,\n' "$q_config_name"
  printf '    "config_sha256": %s\n' "$q_config_sha"
  printf '  },\n'
  printf '  "files": {\n'
  for i in "${!staged[@]}"; do
    f=${staged[$i]}
    q=$(jstr "$f")
    h=$(sha256sum "$release_dir/$f" | cut -d' ' -f1)
    sep=,
    [ "$i" -eq $((${#staged[@]} - 1)) ] && sep=
    printf '    %s: "%s"%s\n' "$q" "$h" "$sep"
  done
  printf '  }\n'
  printf '}\n'
} > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"

echo "write-manifest: $manifest written for $vermagic"
