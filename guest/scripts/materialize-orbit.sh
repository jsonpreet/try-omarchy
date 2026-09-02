#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: materialize-orbit.sh --root ROOT --source ORBIT_SOURCE [--spec SPEC]

Installs the pinned Orbit OS runtime into a staged rootfs. Replaces the
upstream materialize-omarchy step: Orbit's payload is the runtime source tree
(src/), the HUD (shell/), helper scripts, the capability policy, and the
agentd/HUD systemd services. This step only copies files, so it can also be
exercised on macOS during validation.
USAGE
}

fail() {
  echo "materialize-orbit: $*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
root=""
source_dir=""
spec="$guest_dir/spec.json"

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --source)
      source_dir=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

[[ -n $root ]] || fail "--root is required"
[[ $root == /* ]] || fail "--root must be an absolute path"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ -d $source_dir/src/orbit_runtime ]] || fail "source does not look like the Orbit runtime (missing src/orbit_runtime)"
[[ -n $spec ]] || spec="$guest_dir/spec.json"
[[ -f $spec ]] || fail "guest spec not found: $spec"

install_file() {
  local mode=$1
  local from=$2
  local to=$3
  mkdir -p "$(dirname "$to")"
  install -m "$mode" "$from" "$to"
}

orbit_root="$root/opt/orbit"
rm -rf "$orbit_root"
mkdir -p "$orbit_root"

# Copy the runtime, the HUD, and the helper scripts.
copy_tree() {
  local from=$1
  local to=$2
  mkdir -p "$(dirname "$to")"
  cp -a "$from" "$to"
}
copy_tree "$source_dir/src" "$orbit_root/src"
copy_tree "$source_dir/shell" "$orbit_root/shell"
install_file 0755 "$source_dir/scripts/hud-serve.py" "$orbit_root/hud-serve.py"
install_file 0755 "$source_dir/scripts/orbit-chat.py" "$orbit_root/orbit-chat"

# License + provenance markers.
[[ -f $source_dir/LICENSE ]] && install_file 0644 "$source_dir/LICENSE" \
  "$root/usr/share/licenses/orbit/LICENSE"
install_file 0644 "$spec" "$root/usr/share/orbit/build-spec.json"

# Capability policy (v5): write/notify/memory approved by default; everything
# else deny. Human-editable, never model-writable.
install_file 0644 "$source_dir/iso/airootfs/etc/orbit/policy.json" \
  "$root/etc/orbit/policy.json"

# systemd services: agentd + HUD run from multi-user; the live user session
# opens the HUD in Chromium (kiosk service ships in the image, not here).
install_file 0644 "$source_dir/iso/airootfs/etc/systemd/system/orbit-agentd.service" \
  "$root/usr/lib/systemd/system/orbit-agentd.service"
install_file 0644 "$source_dir/iso/airootfs/etc/systemd/system/orbit-hud.service" \
  "$root/usr/lib/systemd/system/orbit-hud.service"
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/orbit-agentd.service \
  "$root/etc/systemd/system/multi-user.target.wants/orbit-agentd.service"
ln -sfn /usr/lib/systemd/system/orbit-hud.service \
  "$root/etc/systemd/system/multi-user.target.wants/orbit-hud.service"

# orbit-check + orbit-chat for the live user.
install_file 0755 "$source_dir/iso/airootfs/usr/local/bin/orbit-check" \
  "$root/usr/local/bin/orbit-check"
install_file 0755 "$source_dir/scripts/orbit-chat.py" \
  "$root/usr/local/bin/orbit-chat"
# orbit-chat must find the runtime without a venv:
mkdir -p "$root/etc/profile.d"
cat > "$root/etc/profile.d/orbit.sh" <<'PROFILE'
export PYTHONPATH=/opt/orbit/src${PYTHONPATH:+:$PYTHONPATH}
export ORBIT_POLICY=/etc/orbit/policy.json
export ORBIT_SANDBOX=/var/lib/orbit/sandbox
PROFILE

# Sandbox + memory dirs, world-validated by agentd at startup.
mkdir -p "$root/var/lib/orbit/sandbox/memory"
chmod 0755 "$root/var/lib/orbit" "$root/var/lib/orbit/sandbox"

echo "materialize-orbit: Orbit runtime staged into $orbit_root"
