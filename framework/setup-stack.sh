#!/usr/bin/env bash
# setup-stack.sh — Generic stack installer that reads any manifest.yaml
#
# Framework-level runner. Takes a stack name (kebab-case per
# conventions.md §3), locates the stack repo, reads its manifest,
# validates it against stack-manifest-spec.md, and installs in order:
#
#   1. Required features (email_relay, vzdump_backup, health_watchdog, ...)
#   2. core_apps from the resolved inheritance chain (in install order —
#      dependencies must come before dependents). See conventions.md §2.2
#      on additive composition: the chain is walked + deduplicated, and
#      each app is classified INSTALL / RECONFIGURE / SKIP based on host
#      state. Idempotent addons make this safe.
#   3. Optional apps (if --include-optional passed)
#   4. Workflows (filtered to those whose stack_dependencies are satisfied)
#   5. default_personas (auto-deploy)
#   6. Stack-specific wire.sh, if the stack repo has one (always runs)
#
# Pre-flight validations refuse to start if the manifest is invalid OR
# the host doesn't meet capacity floor for the resulting TOTAL composition
# (existing + new stack), or if inherits.base_stack_version isn't
# satisfied.
#
# Usage:
#   ./setup-stack.sh <stack-name> [flags]
#
# Required:
#   <stack-name>             Stack identifier (e.g. sobol-foundation, sobol-mirror)
#
# Optional:
#   --stack-path PATH        Path to the stack repo (default: ../stack-<name>)
#   --tokens-file PATH       Tokens file path (default: /root/<name>-tokens.txt)
#   --include-optional       Also install optional_apps from the manifest
#   --skip-workflows         Don't import workflows
#   --skip-personas          Don't deploy default_personas
#   --upgrade                Pull deltas vs. previous install (skip-if-present)
#   --dry-run                Print the install plan without executing
#   --yes, -y                Skip interactive confirmation
#   -h, --help               This help
#
# Examples:
#   ./setup-stack.sh sobol-foundation --tokens-file /root/td-tokens.txt
#   ./setup-stack.sh sobol-mirror --dry-run
#   ./setup-stack.sh creator-studio --include-optional -y
#
# Status: MVP end-to-end (2026-07-01). Validates manifest + resolves
# inheritance chain + classifies each app INSTALL/RECONFIGURE/SKIP +
# runs addons in dependency order + invokes wire.sh if present +
# updates /root/installed-stacks.json state file.
#
# What MVP does NOT yet do (deferred to a future pass, per
# stacks/creator-studio/RUNBOOK.target.md §4):
#   - CT auto-creation via community-scripts helpers. Assumes CTs
#     already exist (from bootstrap-pve.sh or a stack-specific
#     bootstrap). Missing-CT case logs a clear "CT expected but not
#     found — create it first" message and moves on.
#   - Per-stack workflow subset filtering. setup-n8n.sh imports the
#     whole sobol-foundation workflow library at foundation install
#     time; stack manifests declare which workflows they use, but the
#     runtime doesn't yet gate imports by manifest.
#   - Version-aware inheritance validation (base_stack_version).
#     Currently just checks that the base_stack manifest exists.

set -Eeuo pipefail

# ----- defaults -------------------------------------------------------------
STACK_NAME=""
STACK_PATH=""
TOKENS_FILE=""
INCLUDE_OPTIONAL=0
SKIP_WORKFLOWS=0
SKIP_PERSONAS=0
UPGRADE=0
DRY_RUN=0
YES=0
CONTINUE_MODE=0

# Runtime paths — override via env if the operator has a non-standard layout.
SOBOL_FOUNDATION_PATH="${SOBOL_FOUNDATION_PATH:-/root/sobol-foundation}"
PI_PERSONAS_PATH="${PI_PERSONAS_PATH:-/root/pi-personas}"
STATE_FILE="${STATE_FILE:-/root/installed-stacks.json}"

# ----- parse args -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-path)       STACK_PATH="$2"; shift 2 ;;
    --tokens-file)      TOKENS_FILE="$2"; shift 2 ;;
    --include-optional) INCLUDE_OPTIONAL=1; shift ;;
    --skip-workflows)   SKIP_WORKFLOWS=1; shift ;;
    --skip-personas)    SKIP_PERSONAS=1; shift ;;
    --upgrade)          UPGRADE=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --yes|-y)           YES=1; shift ;;
    --continue)         CONTINUE_MODE=1; shift ;;
    -h|--help)          sed -n '2,40p' "$0"; exit 0 ;;
    -*)                 echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$STACK_NAME" ]]; then
        STACK_NAME="$1"
      else
        echo "Unexpected positional arg: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

# ----- helpers --------------------------------------------------------------
log()   { printf "\n\033[1;36m[setup-stack]\033[0m %s\n" "$*"; }
warn()  { printf "\n\033[1;33m[setup-stack]\033[0m %s\n" "$*" >&2; }
die()   { printf "\n\033[1;31m[setup-stack]\033[0m %s\n" "$*" >&2; exit 1; }
run()   { if (( DRY_RUN )); then printf "[dry-run] %s\n" "$*"; else eval "$@"; fi; }

# Validate inputs
[[ -n "$STACK_NAME" ]] || die "Stack name required. See --help."
[[ "$STACK_NAME" =~ ^[a-z][a-z0-9-]*$ ]] || \
  die "Stack name must be kebab-case (lowercase, digits, hyphens). Got: $STACK_NAME"

# Locate the stack folder. Try in order:
#   1. --stack-path explicit override (operator knows best)
#   2. ../stacks/<name>/ (the monorepo of all derived stacks including
#      sobol-foundation; see conventions.md §3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$STACK_PATH" ]]; then
  if [[ -d "$SCRIPT_DIR/../stacks/${STACK_NAME}" ]]; then
    STACK_PATH="$SCRIPT_DIR/../stacks/${STACK_NAME}"
  fi
fi

# Populated by resolve_inheritance_chain, consumed by install_core_apps +
# import_workflows.
RESOLVED_CORE_APPS=()
[[ -n "$STACK_PATH" && -d "$STACK_PATH" ]] || \
  die "Stack folder not found at ../stacks/${STACK_NAME}/. Override with --stack-path."

MANIFEST="$STACK_PATH/manifest.yaml"
[[ -f "$MANIFEST" ]] || die "Manifest missing: $MANIFEST"

# Locate tokens file
if [[ -z "$TOKENS_FILE" ]]; then
  for f in "/root/${STACK_NAME}-tokens.txt" "/root/td-tokens.txt" "/root/sobol-tokens.txt"; do
    [[ -f "$f" ]] && { TOKENS_FILE="$f"; break; }
  done
fi

# Require yq for YAML parsing — it's the standard tool, install with apt
command -v yq >/dev/null || die "yq required: apt install -y yq"
command -v jq >/dev/null || die "jq required: apt install -y jq"

# ----- manifest reader helpers ---------------------------------------------
# Each helper reads a single field from the manifest. Centralizes the yq
# invocation so a future yq version change touches one place.
m_get() { yq -r "$1 // \"\"" "$MANIFEST"; }
m_arr() { yq -r "$1 // [] | .[]" "$MANIFEST"; }

# ----- validate manifest ----------------------------------------------------
validate_manifest() {
  log "Validating manifest at $MANIFEST..."
  local missing=()
  for f in name display_name version tier maintainer description; do
    [[ -n "$(m_get ".${f}")" ]] || missing+=("$f")
  done
  if (( ${#missing[@]} > 0 )); then
    die "Manifest missing required identity fields: ${missing[*]}"
  fi

  local mname mtier
  mname="$(m_get '.name')"
  mtier="$(m_get '.tier')"
  [[ "$mname" == "$STACK_NAME" ]] || \
    die "Manifest name '$mname' doesn't match --stack-name '$STACK_NAME'"
  case "$mtier" in
    foundation|mirror|office-in-a-box|premium|custom) ;;
    *) die "Manifest tier '$mtier' not in spec — expected foundation/mirror/office-in-a-box/premium/custom" ;;
  esac

  # Required: core_apps non-empty
  [[ -n "$(yq -r '.core_apps // [] | .[]' "$MANIFEST")" ]] || \
    die "Manifest core_apps is empty — at least one app required"

  # Required: features block present
  [[ -n "$(m_get '.features')" ]] || die "Manifest features block missing"

  log "  ✓ Manifest valid"
}

# ----- capacity check -------------------------------------------------------
# Refuse to install if the host doesn't meet the manifest's capacity floor.
# Operators with hardware just barely above the floor get a warning.
capacity_check() {
  log "Capacity check..."
  local min_ram min_disk min_cpu
  min_ram="$(m_get '.capacity.ram_min_gb')"
  min_disk="$(m_get '.capacity.disk_min_gb')"
  min_cpu="$(m_get '.capacity.cpu_min_cores')"

  if [[ -n "$min_ram" ]]; then
    local actual_ram_gb
    actual_ram_gb="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$actual_ram_gb" -lt "$min_ram" ]]; then
      die "RAM capacity floor not met: have ${actual_ram_gb}GB, manifest requires ${min_ram}GB."
    fi
    log "  ✓ RAM: ${actual_ram_gb}GB available (min ${min_ram}GB)"
  fi

  if [[ -n "$min_cpu" ]]; then
    local actual_cpu
    actual_cpu="$(nproc 2>/dev/null || echo 0)"
    if [[ "$actual_cpu" -lt "$min_cpu" ]]; then
      die "CPU capacity floor not met: have $actual_cpu cores, manifest requires $min_cpu."
    fi
    log "  ✓ CPU: $actual_cpu cores available (min $min_cpu)"
  fi

  if [[ -n "$min_disk" ]]; then
    local actual_disk_gb
    actual_disk_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}' || echo 0)"
    if [[ "$actual_disk_gb" -lt "$min_disk" ]]; then
      warn "Disk free below manifest floor: have ${actual_disk_gb}GB free, manifest requires ${min_disk}GB."
      warn "Continuing — this is a warning, not a blocker (apt cache + thin pool can cause false positives)."
    else
      log "  ✓ Disk: ${actual_disk_gb}GB free (min ${min_disk}GB)"
    fi
  fi
}

# ----- print install plan ---------------------------------------------------
print_plan() {
  log "================================================================"
  log "Install plan for stack: $(m_get '.display_name') v$(m_get '.version')"
  log "================================================================"
  log "  Tier:          $(m_get '.tier')"
  log "  Maintainer:    $(m_get '.maintainer')"
  log "  Tokens file:   ${TOKENS_FILE:-(none found)}"
  log "  Stack path:    $STACK_PATH"
  log " "

  log "Inherits from:"
  log "  Framework:     $(m_get '.inherits.framework') $(m_get '.inherits.framework_version')"
  local base_stack
  base_stack="$(m_get '.inherits.base_stack')"
  if [[ -n "$base_stack" && "$base_stack" != "null" ]]; then
    log "  Base stack:    $base_stack $(m_get '.inherits.base_stack_version')"
  else
    log "  Base stack:    (none — standalone foundation)"
  fi
  log " "

  log "Required features to install:"
  while IFS= read -r feat; do
    local val
    val="$(m_get ".features.${feat}")"
    [[ "$val" == "required" ]] && log "  - $feat"
  done < <(yq -r '.features | keys | .[]' "$MANIFEST")
  log " "

  log "Core apps (in install order):"
  while IFS= read -r app; do
    log "  - $app"
  done < <(m_arr '.core_apps')
  log " "

  if (( INCLUDE_OPTIONAL )); then
    log "Optional apps (--include-optional):"
    while IFS= read -r app; do
      log "  - $app"
    done < <(m_arr '.optional_apps')
    log " "
  fi

  if (( ! SKIP_WORKFLOWS )); then
    log "Workflows to import:"
    while IFS= read -r wf; do
      log "  - $wf"
    done < <(m_arr '.workflows')
    log " "
  fi

  if (( ! SKIP_PERSONAS )); then
    local has_default
    has_default="$(m_arr '.default_personas' | head -1 || true)"
    if [[ -n "$has_default" ]]; then
      log "Default personas (auto-deploy):"
      while IFS= read -r p; do
        log "  - $p"
      done < <(m_arr '.default_personas')
      log " "
    fi
  fi
}

# ----- confirm -------------------------------------------------------------
confirm() {
  (( YES )) && return 0
  (( DRY_RUN )) && return 0
  printf "\nProceed with install? [y/N] " >&2
  local answer
  read -r answer
  [[ "$answer" =~ ^[Yy] ]] || die "Cancelled by operator."
}

# ----- workflow dependency validator ---------------------------------------
# For a given workflow JSON, check that its meta.stack_dependencies.required_apps
# are all in the manifest's installed app set. Returns 0 if OK, 1 if missing
# deps + lists them.
workflow_deps_satisfied() {
  local wf_path="$1"
  local installed_apps_csv="$2"

  local req_apps
  req_apps="$(jq -r '.meta.stack_dependencies.required_apps // [] | .[]' "$wf_path" 2>/dev/null || true)"

  local missing=()
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    if [[ ",$installed_apps_csv," != *",$req,"* ]]; then
      missing+=("$req")
    fi
  done <<< "$req_apps"

  if (( ${#missing[@]} > 0 )); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

# ===== Inheritance chain + app classification ==============================

# resolve_inheritance_chain — union core_apps from this stack + its base_stack
# (recursively). Deduplicates, preserving install order (base first). Writes
# to global RESOLVED_CORE_APPS array.
#
# MVP: only handles one level of inheritance (creator-studio → sobol-foundation).
# When we go deeper (e.g. custom customer overlays), extend this to a real
# recursive walk.
resolve_inheritance_chain() {
  log "Resolving inheritance chain..."
  RESOLVED_CORE_APPS=()

  local base_stack base_version
  base_stack="$(m_get '.inherits.base_stack')"
  base_version="$(m_get '.inherits.base_stack_version')"

  # 1. Load base_stack core_apps first (they install before dependents)
  if [[ -n "$base_stack" && "$base_stack" != "null" ]]; then
    local base_manifest="$SCRIPT_DIR/../stacks/${base_stack}/manifest.yaml"
    if [[ -f "$base_manifest" ]]; then
      log "  Base stack: $base_stack (version constraint: ${base_version:-any})"
      while IFS= read -r app; do
        [[ -n "$app" ]] && RESOLVED_CORE_APPS+=("$app")
      done < <(yq -r '.core_apps // [] | .[]' "$base_manifest")
    else
      warn "  Base stack manifest not found: $base_manifest — installing only this stack's core_apps"
    fi
  else
    log "  No base_stack — this stack is a root"
  fi

  # 2. Union this stack's core_apps, deduping against what's already in the list
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    local already=0 existing
    for existing in "${RESOLVED_CORE_APPS[@]}"; do
      [[ "$existing" == "$app" ]] && { already=1; break; }
    done
    (( already )) || RESOLVED_CORE_APPS+=("$app")
  done < <(m_arr '.core_apps')

  log "  Resolved ${#RESOLVED_CORE_APPS[@]} apps: ${RESOLVED_CORE_APPS[*]}"
}

# find_ct_by_hostname — return CTID for a CT with the given hostname, or ""
find_ct_by_hostname() {
  local target="$1"
  pct list 2>/dev/null | awk -v t="$target" 'NR>1 && $3 == t {print $1; exit}'
}

# classify_app — echo "INSTALL", "RECONFIGURE", or "SKIP" for one app.
#
# MVP heuristic:
#   - CT missing (no pct with matching hostname) → INSTALL
#     (which currently just runs the addon and lets IT complain if CT
#      creation is needed; auto CT creation is future work)
#   - CT present + addon has a state marker → SKIP
#   - CT present + no marker → RECONFIGURE (idempotent per §2.2)
classify_app() {
  local app="$1"
  local ctid
  ctid="$(find_ct_by_hostname "$app")"
  if [[ -z "$ctid" ]]; then
    echo "INSTALL"
  else
    # State marker convention: addons that want to signal "already done at
    # version N" write /var/lib/setup-stack/<app>.done in the CT. Absent
    # marker = safe to re-run (addons are idempotent per §2.2).
    if pct exec "$ctid" -- test -f "/var/lib/setup-stack/${app}.done" 2>/dev/null; then
      echo "SKIP"
    else
      echo "RECONFIGURE"
    fi
  fi
}

# find_addon_script — locate setup-<app>.sh. Returns full path, or "" if
# no script found (which is normal for foundation apps handled by
# bootstrap-pve.sh rather than per-app addons).
#
# Search order per conventions.md §2.1:
#   1. sobol-foundation/addons/setup-<app>.sh (the library — normal case)
#   2. $STACK_PATH/addons/setup-<app>.sh (stack-specific — edge case)
find_addon_script() {
  local app="$1"
  local lib_path="$SOBOL_FOUNDATION_PATH/addons/setup-${app}.sh"
  local stack_path="$STACK_PATH/addons/setup-${app}.sh"
  if [[ -x "$lib_path" ]]; then
    echo "$lib_path"
  elif [[ -x "$stack_path" ]]; then
    echo "$stack_path"
  else
    echo ""
  fi
}

# ===== State file ==========================================================
# /root/installed-stacks.json — simple JSON array of installed stacks.
# Used by uninstall logic (future) to track shared-addon dependencies.

state_read() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo '[]'
  fi
}

state_record_install() {
  local name="$1" version="$2"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if (( DRY_RUN )); then
    printf "[dry-run] would record %s v%s in %s\n" "$name" "$version" "$STATE_FILE"
    return 0
  fi

  local current
  current="$(state_read)"

  # Upsert: drop any existing entry with same name, append current
  echo "$current" | jq --arg n "$name" --arg v "$version" --arg t "$now" \
    'map(select(.name != $n)) + [{"name": $n, "version": $v, "installed_at": $t}]' \
    > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# ===== Real install steps (MVP end-to-end) =================================

# install_required_features — dispatch feature keys to their canonical
# library addons. Idempotent — each library addon detects satisfied state
# and skips (per §2.2 additive-composition rule).
#
# Feature-key → addon mapping is defined here. When a new feature is added
# to the manifest spec, add the mapping row.
install_required_features() {
  log "===> Installing required features..."

  declare -A FEATURE_ADDON=(
    [email_relay]="setup-pve-email.sh"
    [vzdump_backup]="setup-vzdump-schedule.sh"
    [health_watchdog]="setup-health-watchdog.sh"
    [gitea_email]="setup-gitea-email.sh"
    [config_backup]="setup-pve-etc-backup.sh"
    [usb_backup_target]="setup-usb-backup.sh"
    [port80_redirect]="setup-port80-redirect.sh"
    [smb_share]="setup-smb-share.sh"
    [new_pi_agent]="setup-new-pi-agent.sh"
  )

  local ran=0
  while IFS= read -r feat; do
    local val
    val="$(m_get ".features.${feat}")"
    [[ "$val" != "required" ]] && continue

    local addon="${FEATURE_ADDON[$feat]:-}"
    if [[ -z "$addon" ]]; then
      warn "  UNKNOWN feature key: $feat (no addon mapping — add to FEATURE_ADDON)"
      continue
    fi

    local addon_path="$SOBOL_FOUNDATION_PATH/addons/$addon"
    if [[ ! -x "$addon_path" ]]; then
      warn "  MISSING addon for feature '$feat': $addon_path"
      continue
    fi

    log "  Installing feature '$feat' via $addon..."
    if (( DRY_RUN )); then
      printf "[dry-run] %s%s\n" "$addon_path" "${TOKENS_FILE:+ --tokens-file $TOKENS_FILE}"
    else
      "$addon_path" ${TOKENS_FILE:+--tokens-file "$TOKENS_FILE"} 2>&1 | sed 's/^/    /'
    fi
    ((ran++))
  done < <(yq -r '.features | keys | .[]' "$MANIFEST")

  log "  Ran $ran required feature(s)."
}

# install_core_apps — walks the resolved inheritance chain. For each app:
#   classify → find_addon_script → run (if script found + not SKIP)
#
# Idempotent per §2.2: addons detect their own state and no-op when already
# configured, so RECONFIGURE and re-runs of INSTALL are both safe.
install_core_apps() {
  log "===> Installing core_apps (walking resolved inheritance chain)..."

  # RESOLVED_CORE_APPS is populated by resolve_inheritance_chain
  if [[ ${#RESOLVED_CORE_APPS[@]} -eq 0 ]]; then
    warn "  RESOLVED_CORE_APPS empty — call resolve_inheritance_chain first"
    return 0
  fi

  local install_count=0 reconfigure_count=0 skip_count=0
  for app in "${RESOLVED_CORE_APPS[@]}"; do
    local action script
    action="$(classify_app "$app")"
    script="$(find_addon_script "$app")"

    case "$action" in
      SKIP)
        log "  [SKIP]        $app (already at target state)"
        ((skip_count++))
        ;;
      RECONFIGURE|INSTALL)
        if [[ -z "$script" ]]; then
          # No addon script — assumed to be a foundation app handled by
          # bootstrap-pve.sh (gitea, homepage via community-scripts). Log
          # and move on; complaining is the operator's cue that they
          # need to run bootstrap-pve.sh first.
          log "  [$action]  $app (no addon script — assumed handled by bootstrap-pve.sh)"
        else
          log "  [$action]  $app via $(basename "$script")"
          if (( DRY_RUN )); then
            printf "[dry-run] %s%s\n" "$script" "${TOKENS_FILE:+ --tokens-file $TOKENS_FILE}"
          else
            "$script" ${TOKENS_FILE:+--tokens-file "$TOKENS_FILE"} 2>&1 | sed 's/^/    /' || {
              warn "  $app addon returned non-zero — continuing (may need manual retry)"
            }
          fi
        fi
        [[ "$action" == "INSTALL" ]] && ((install_count++)) || ((reconfigure_count++))
        ;;
    esac
  done

  log "  Summary: $install_count INSTALL, $reconfigure_count RECONFIGURE, $skip_count SKIP"
}

install_optional_apps() {
  (( INCLUDE_OPTIONAL )) || return 0
  log "===> Installing optional_apps..."

  local count=0
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    local script action
    script="$(find_addon_script "$app")"
    action="$(classify_app "$app")"

    if [[ "$action" == "SKIP" ]]; then
      log "  [SKIP] $app (already at target state)"
      continue
    fi

    if [[ -z "$script" ]]; then
      log "  [SKIP] $app — no addon script found in library"
      continue
    fi

    log "  [$action] $app via $(basename "$script")"
    if (( DRY_RUN )); then
      printf "[dry-run] %s\n" "$script"
    else
      "$script" ${TOKENS_FILE:+--tokens-file "$TOKENS_FILE"} 2>&1 | sed 's/^/    /' || \
        warn "  $app returned non-zero"
    fi
    ((count++))
  done < <(m_arr '.optional_apps')

  log "  Ran $count optional app(s)."
}

# import_workflows — MVP: all foundation library workflows are already
# imported by setup-n8n.sh at foundation install time. Per-stack subset
# filtering is a future enhancement (currently the manifest declares what
# it *uses*, but the runtime imports the whole library).
#
# For manifest workflows that live in stacks/<name>/addons/n8n/workflows/
# (rare, none currently), we'd POST them to n8n's API. Not exercised yet.
import_workflows() {
  (( SKIP_WORKFLOWS )) && return 0
  log "===> Workflows..."

  local imported=0 skipped=0
  local installed
  installed="$(printf '%s\n' "${RESOLVED_CORE_APPS[@]}" | paste -sd,)"

  while IFS= read -r wf; do
    [[ -n "$wf" ]] || continue
    local wf_path
    # Library workflow — already imported at foundation install
    if [[ -f "$SOBOL_FOUNDATION_PATH/addons/n8n/workflows/${wf}.json" ]]; then
      log "  [LIB]  $wf (imported at foundation install by setup-n8n.sh)"
      ((skipped++))
      continue
    fi
    # Stack-specific workflow
    wf_path="$STACK_PATH/addons/n8n/workflows/${wf}.json"
    if [[ ! -f "$wf_path" ]]; then
      warn "  [MISS] $wf — not found in library or stack path"
      continue
    fi

    if workflow_deps_satisfied "$wf_path" "$installed" >/dev/null 2>&1; then
      log "  [STACK] $wf (would POST to n8n — MVP: manual import required)"
      # TODO: real n8n API POST — needs N8N_HOST + N8N_OWNER_EMAIL +
      # N8N_OWNER_PASSWORD from td-tokens. Not exercised yet.
      ((imported++))
    else
      local missing
      missing="$(workflow_deps_satisfied "$wf_path" "$installed" || true)"
      warn "  [SKIP] $wf — deps missing: $(echo "$missing" | paste -sd,)"
    fi
  done < <(m_arr '.workflows')

  log "  $skipped library workflows (already imported), $imported stack-specific queued"
}

deploy_default_personas() {
  (( SKIP_PERSONAS )) && return 0
  log "===> Deploying default_personas..."

  if [[ ! -x "$PI_PERSONAS_PATH/deploy-persona.sh" ]]; then
    warn "  PI_PERSONAS_PATH/deploy-persona.sh not found at $PI_PERSONAS_PATH"
    warn "  Set PI_PERSONAS_PATH env var if pi-personas lives elsewhere. Skipping."
    return 0
  fi

  local count=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    log "  Deploying persona: $p"
    if (( DRY_RUN )); then
      printf "[dry-run] %s/deploy-persona.sh %s\n" "$PI_PERSONAS_PATH" "$p"
    else
      "$PI_PERSONAS_PATH/deploy-persona.sh" "$p" 2>&1 | sed 's/^/    /' || \
        warn "  Persona '$p' deploy returned non-zero"
    fi
    ((count++))
  done < <(m_arr '.default_personas')

  log "  Deployed $count default persona(s)."
}

# run_wire_sh — call stacks/<name>/wire.sh if present. Always runs (even
# on --continue). The graceful-skip pattern inside wire.sh handles
# idempotence.
run_wire_sh() {
  local wire="$STACK_PATH/wire.sh"
  if [[ ! -x "$wire" ]]; then
    log "===> No wire.sh at $wire — skipping composition wiring"
    return 0
  fi
  log "===> Running composition wiring: $wire"
  if (( DRY_RUN )); then
    printf "[dry-run] %s\n" "$wire"
  else
    "$wire" 2>&1 | sed 's/^/    /' || \
      warn "  wire.sh returned non-zero — check its Phase summary + operator prereqs"
  fi
}

# ----- main -----------------------------------------------------------------
# Two modes:
#   default:    validate + plan + confirm + everything from features →
#               apps → workflows → personas → wire.sh + state record
#   --continue: skip features + apps + workflows + personas (assumed
#               already done); just re-run wire.sh + reachability. Use
#               after operator has completed manual admin signups + API
#               key minting + CF Zero Trust hostname config.
main() {
  validate_manifest

  if (( CONTINUE_MODE )); then
    log "================================================================"
    log "==> --continue mode: skipping mechanical steps, running wire.sh only"
    log "================================================================"
    run_wire_sh
    log "================================================================"
    log "==> --continue done."
    log " "
    log "Verify from the RUNBOOK's Phase 9 (end-to-end smoke tests)."
    log "================================================================"
    return 0
  fi

  (( DRY_RUN )) || capacity_check
  resolve_inheritance_chain
  print_plan
  confirm

  install_required_features
  install_core_apps
  install_optional_apps
  import_workflows
  deploy_default_personas
  run_wire_sh

  # Record the install (or update the existing record with new version)
  state_record_install "$(m_get '.name')" "$(m_get '.version')"

  # Emit the operator's next-steps banner. See RUNBOOK.target.md §2 for
  # the format we're targeting. wire.sh's summary already tells the
  # operator which phases skipped for missing prereqs — we just close.
  log "================================================================"
  log "==> Mechanical install complete."
  log " "
  log "  Stack:        $(m_get '.display_name') v$(m_get '.version')"
  log "  Manifest:     $MANIFEST"
  log "  Tokens:       ${TOKENS_FILE:-(none used)}"
  log "  State file:   $STATE_FILE"
  log " "
  log "If wire.sh reported SKIP phases (missing GHOST_ADMIN_API_KEY etc.),"
  log "complete the manual steps documented in the wire.sh SKIP messages,"
  log "then re-run to finish the wiring:"
  log "  $0 $STACK_NAME --continue"
  log " "
  log "Then verify per the RUNBOOK's Phase 9 (end-to-end smoke tests)."
  log "================================================================"
}

main "$@"
