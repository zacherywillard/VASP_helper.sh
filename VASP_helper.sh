#!/usr/bin/env bash
# VASP_helper.sh
# ----------------
# Automates creation and continuation of VASP defect jobs by:
#   • Creating charged defects from neutral structures (initial relax)
#   • Continuing existing calculations (final relax / static)
#   • Automatically setting NELECT
#   • Optional spin handling based on NELECT parity
#   • Optional safety checks (CHGCAR/WAVECAR consistency)
#
# The goal of this script is to eliminate repetitive setup steps
# and enforce consistent, safe workflows for large defect datasets.

set -euo pipefail

###############################################################################
# Globals & CLI parsing
###############################################################################

MODE=""
STAGE=""               # initial|final (only for relax)
CHARGED_ONLY=false     # -Q
NEUTRAL_ONLY=false     # -N
SOURCE_ROOT=""
NEUTRAL_ROOT=""        # defaults to SOURCE_ROOT when needed
CHARGES=()             # default later: -2 -1 1 2
SPIN_MODE=false        # --spin
SAFETY=1               # 0 ignore, 1 submit-safe-only, 2 all-or-nothing
SUBMIT=true            # -q to disable
VERBOSE=true          # -v/--verbose
LOG_FILE="helper.log"

# track work
declare -a CREATED_JOBS=()
declare -A JOB_UNSAFE_REASON=()  # map: dir -> reason string
declare -a JOBS_TO_SUBMIT=()

usage() {
  cat <<'EOF'
Usage:
  VASP_helper.sh --mode relax --stage initial|final [options]
  VASP_helper.sh --mode static [options]

Required:
  --mode            relax | static
  --stage           initial | final      (required if --mode relax)
  --source_root     PATH                 (defect dirs 1 level deep)

Optional selectors:
  -Q                charged-only
  -N                neutral-only
  --neutral_root    PATH                 (for creating charges from neutrals;
                                          defaults to --source_root if omitted)
  --charges "list"  space-separated list of charges to create, e.g. "-2 -1 1 2"
                    (default: -2 -1 1 2)

Behavior controls:
  --spin            enable ISPIN=2 parity handling (even NELECT deletes ISPIN)
  --safety N        0 = ignore all safety checks and submit all
                    1 = submit only jobs that pass safety checks (default)
                    2 = if ANY job fails → submit NONE
  -q                dry-run; prepare but do not submit jobs
  -v, --verbose     print verbose logs to console and always write helper.log
  -h, --help        show this help

Notes:
 • Directory names are expected like <defect>_<site>_<charge>, e.g. Cd_i_-1, Se_Cd_0.
 • For '--mode relax --stage initial' you MUST use -Q. This creates charged
   states from neutrals in --neutral_root (defaulting to --source_root).
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

log_init() { : > "$LOG_FILE"; }
log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" >> "$LOG_FILE"
  $VERBOSE && echo "[$ts] $*"
}

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --stage) STAGE="${2:-}"; shift 2 ;;
      -Q) CHARGED_ONLY=true; shift ;;
      -N) NEUTRAL_ONLY=true; shift ;;
      --source_root) SOURCE_ROOT="${2:-}"; shift 2 ;;
      --neutral_root) NEUTRAL_ROOT="${2:-}"; shift 2 ;;
      --charges) read -r -a CHARGES <<< "${2:-}"; shift 2 ;;
      --spin) SPIN_MODE=true; shift ;;
      --safety)
        SAFETY="${2:-}"
        [[ "$SAFETY" =~ ^[012]$ ]] || die "--safety must be 0, 1 or 2"
        shift 2 ;;
      -q) SUBMIT=false; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $arg (see --help)" ;;
    esac
  done

  # Defaults
  if ((${#CHARGES[@]}==0)); then
    CHARGES=(-2 -1 1 2)
  fi
  if [[ -z "${NEUTRAL_ROOT:-}" ]]; then
    NEUTRAL_ROOT="$SOURCE_ROOT"
  fi

  # Basic validation
  [[ -n "$MODE" ]] || die "--mode is required"
  if [[ "$MODE" == "relax" ]]; then
    [[ -n "$STAGE" ]] || die "--stage is required for --mode relax (initial|final)"
    [[ "$STAGE" =~ ^(initial|final)$ ]] || die "--stage must be initial or final"
  else
    [[ -z "${STAGE:-}" || "$STAGE" == "" ]] || die "--stage not allowed for --mode static"
  fi

  [[ -n "$SOURCE_ROOT" ]] || die "--source_root is required"
  [[ -d "$SOURCE_ROOT" ]] || die "source_root not found: $SOURCE_ROOT"

  if $CHARGED_ONLY && $NEUTRAL_ONLY; then
    die "Cannot specify both -Q (charged-only) and -N (neutral-only)"
  fi

  if [[ "$MODE" == "relax" && "$STAGE" == "initial" ]]; then
    $CHARGED_ONLY || die "--mode relax --stage initial requires -Q (charged-only)"
    $NEUTRAL_ONLY && die "-N is invalid for initial stage"
    [[ -d "$NEUTRAL_ROOT" ]] || die "neutral_root not found: $NEUTRAL_ROOT"
  fi
}

###############################################################################
# Generic helpers (file choices, INCAR edits, parsing)
###############################################################################

choose_file() {
  # prefer local override ./NAME, else SRC/NAME, else empty
  local name="$1" srcdir="$2"
  if [[ -f "./$name" ]]; then echo "./$name"
  elif [[ -f "$srcdir/$name" ]]; then echo "$srcdir/$name"
  else echo ""; fi
}

prefer_contcar_or_poscar() {
  local dir="$1"
  if [[ -f "$dir/CONTCAR" ]]; then echo "$dir/CONTCAR"
  elif [[ -f "$dir/POSCAR" ]]; then echo "$dir/POSCAR"
  else echo ""; fi
}

poscar_signature() {
  # return "line6|line7" to check species/count identity
  local pos="$1"
  awk 'NR==6{l6=$0} NR==7{l7=$0;print l6 "|" l7; exit}' "$pos" 2>/dev/null || true
}

incar_has_key() {
  local key="$1" file="$2"
  awk -v K="$key" '
    BEGIN{IGNORECASE=1}
    /^[[:space:]]*#/ {next}
    {sub(/[#!].*$/,"",$0)}
    $0 ~ "^[[:space:]]*"K"[[:space:]]*=" {found=1}
    END{exit(found?0:1)}
  ' "$file"
}

incar_get_val() {
  local key="$1" file="$2"
  awk -v K="$key" '
    BEGIN{IGNORECASE=1}
    /^[[:space:]]*#/ {next}
    {sub(/[#!].*$/,"",$0)}
    $0 ~ "^[[:space:]]*"K"[[:space:]]*=" {
      sub("^[[:space:]]*"K"[[:space:]]*=[[:space:]]*","",$0)
      gsub(/[[:space:]]+$/,"",$0)
      print $0; exit 0
    }
  ' "$file"
}

incar_replace_same_line() {
  # Replace ONLY the first occurrence "KEY = ..." line with "KEY = VALUE"
  # preserving position. Case-insensitive key match.
  local key="$1" value="$2" file="$3"
  awk -v K="$key" -v V="$value" '
    BEGIN{IGNORECASE=1; replaced=0}
    {
      line=$0
      nocom=line; sub(/[#!].*$/,"",nocom)
      if(!replaced && nocom ~ "^[[:space:]]*"K"[[:space:]]*="){
        print K " = " V
        replaced=1
      } else {
        print line
      }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

incar_delete_line_key() {
  # Delete ONLY the first line containing KEY=...
  local key="$1" file="$2"
  awk -v K="$key" '
    BEGIN{IGNORECASE=1; deleted=0}
    {
      line=$0
      nocom=line; sub(/[#!].*$/,"",nocom)
      if(!deleted && nocom ~ "^[[:space:]]*"K"[[:space:]]*="){
        deleted=1; next
      } else { print line }
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

incar_set_or_append() {
  # If KEY exists: replace same line; else append "KEY = VALUE" with a preceding newline.
  local key="$1" value="$2" file="$3"
  if incar_has_key "$key" "$file"; then
    incar_replace_same_line "$key" "$value" "$file"
  else
    printf "\n%s = %s\n" "$key" "$value" >> "$file"
  fi
}

extract_nelect_last_outcar() {
  local out="$1"
  awk '/NELECT *=/ {val=$3} END{if(val!="") printf "%.6f\n", val+0}' "$out" 2>/dev/null || true
}

nelect_from_potcar_poscar() {
  local pot="$1" pos="$2"
  [[ -f "$pot" && -f "$pos" ]] || { echo ""; return; }
  mapfile -t counts < <(awk 'NR==7{for(i=1;i<=NF;i++) print $i+0}' "$pos")
  ((${#counts[@]})) || { echo ""; return; }
  mapfile -t zvals < <(awk '
    BEGIN{IGNORECASE=1; blk=0}
    /^ *TITEL/{blk++}
    /ZVAL[[:space:]]*=/{
      if (match($0,/ZVAL[[:space:]]*=[[:space:]]*([0-9.]+)/,m)) z[blk]=m[1]
    }
    END{for(i=1;i<=blk;i++) if(i in z) print z[i]}
  ' "$pot")
  ((${#zvals[@]} == ${#counts[@]})) || { echo ""; return; }

  awk -v cl="$(printf '%s ' "${counts[@]}")" -v zl="$(printf '%s ' "${zvals[@]}")" '
    BEGIN{
      split(cl,c); split(zl,z); s=0;
      for(i=1;i<=length(c);i++){ s += c[i]*z[i]; }
      printf "%.6f\n", s+0
    }'
}

count_kpoints() {
  # Universal: supports explicit count, Monkhorst-Pack, Gamma, or explicit list.
  local kpts="$1"
  [[ -f "$kpts" ]] || { echo 0; return; }
  awk '
    function isnum(x){ return (x ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) }
    BEGIN{n=0}
    {
      gsub(/\r/,"")
      if($0 ~ /^[[:space:]]*$/) next
      if($0 ~ /^[[:space:]]*#/ ) next
      L[++n]=$0
    }
    END{
      if(n<2){ print 0; exit }
      # explicit mode: second line is count > 0
      if (L[2] ~ /^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$/) {
        c=L[2]+0; if(c>0){ print int(c); exit }
      }
      # automatic grid (Monkhorst/Gamma)
      if (n>=4){
        low=tolower(L[3])
        if (index(low,"monkhorst") || index(low,"gamma")){
          split(L[4],a)
          if (isnum(a[1]) && isnum(a[2]) && isnum(a[3])){
            p=int(a[1]+0)*int(a[2]+0)*int(a[3]+0)
            if(p>0){ print p; exit }
          }
        }
      }
      # fallback: count lines that look like kx ky kz [w]
      cnt=0
      for(i=3;i<=n;i++){
        split(L[i],b)
        if (isnum(b[1]) && isnum(b[2]) && isnum(b[3])) cnt++
      }
      print cnt
    }' "$kpts"
}

get_dir_charge_suffix() {
  local name="$1"
  local suf="${name##*_}"
  if [[ "$suf" =~ ^-?[0-9]+$ ]]; then
    echo "$suf"
  else
    echo ""
  fi
}

###############################################################################
# Safety checks
###############################################################################

safety_check_job() {
  # Evaluate safety of a prepared job dir (after files are copied/edited).
  # Records JOB_UNSAFE_REASON[job_dir] on failure. Returns 0(safe)/1(unsafe).
  local dir="$1"
  local incar="$dir/INCAR"
  local kpoints="$dir/KPOINTS"
  local chg="$dir/CHGCAR"
  local wav="$dir/WAVECAR"

  local unsafe_reason=()

  # (1) CHGCAR safety if ICHARG=1
  if incar_has_key "ICHARG" "$incar"; then
    local ich; ich="$(incar_get_val "ICHARG" "$incar" || true)"
    ich="$(echo "$ich" | awk '{print int($1)+0}')"
    if (( ich == 1 )); then
      if [[ ! -s "$chg" ]]; then
        unsafe_reason+=("ICHARG=1 but CHGCAR missing or empty")
        log "Unsafe ($dir): ICHARG=1 but CHGCAR missing/empty"
      fi
    fi
  fi

  # (2) WAVECAR safety if ISTART in {1,2,3}
  if incar_has_key "ISTART" "$incar"; then
    local ist; ist="$(incar_get_val "ISTART" "$incar" || true)"
    ist="$(echo "$ist" | awk '{print int($1)+0}')"
    if (( ist>=1 && ist<=3 )); then
      if [[ ! -f "$wav" ]]; then
        unsafe_reason+=("ISTART=$ist but WAVECAR missing")
        log "Unsafe ($dir): ISTART=$ist but WAVECAR missing"
      fi
    fi
  fi

  if ((${#unsafe_reason[@]})); then
    JOB_UNSAFE_REASON["$dir"]="$(IFS='; '; echo "${unsafe_reason[*]}")"
    return 1
  fi
  return 0
}

###############################################################################
# Preparation helpers (copy/edit logic)
###############################################################################

copy_inputs_from() {
  # Copy POSCAR/INCAR/KPOINTS/POTCAR/job.vasp6 into DST, honoring global overrides.
  local src="$1" dst="$2"

  mkdir -p "$dst"

  local pos; pos="$(prefer_contcar_or_poscar "$src")"
  [[ -n "$pos" ]] || die "Missing POSCAR/CONTCAR in $src"
  cp -f "$pos" "$dst/POSCAR"

  local incar_src kpts_src pot_src job_src
  incar_src="$(choose_file "INCAR" "$src")"
  kpts_src="$(choose_file "KPOINTS" "$src")"
  pot_src="$(choose_file "POTCAR" "$src")"
  job_src="$(choose_file "job.vasp6" "$src")"

  [[ -n "$incar_src" ]] || die "Missing INCAR (global or in $src)"
  [[ -n "$kpts_src"  ]] || die "Missing KPOINTS (global or in $src)"
  [[ -n "$pot_src"   ]] || die "Missing POTCAR (global or in $src)"
  [[ -n "$job_src"   ]] || die "Missing job.vasp6 (global or in $src)"

  cp -f "$incar_src" "$dst/INCAR"
  cp -f "$kpts_src"  "$dst/KPOINTS"
  cp -f "$pot_src"   "$dst/POTCAR"
  cp -f "$job_src"   "$dst/job.vasp6"
}

copy_density_if_safe_or_forced() {
  # Decide whether to copy CHGCAR/WAVECAR from SRC into DST.
  # Respect INCAR tags and structure unless SAFETY=0 (force).
  local src="$1" dst="$2"

  local incar="$dst/INCAR"
  local src_pos dst_pos
  src_pos="$(prefer_contcar_or_poscar "$src")"
  dst_pos="$dst/POSCAR"
  local sig_src sig_dst
  sig_src="$(poscar_signature "$src_pos")"
  sig_dst="$(poscar_signature "$dst_pos")"

  if (( SAFETY == 0 )); then
    [[ -f "$src/CHGCAR" ]] && cp -f "$src/CHGCAR" "$dst/CHGCAR" || true
    [[ -f "$src/WAVECAR" ]] && cp -f "$src/WAVECAR" "$dst/WAVECAR" || true
    log "Force-copy density/WAVEs (safety=0) from $src → $dst"
    return
  fi

  # CHGCAR only if ICHARG=1 AND structures match
  if incar_has_key "ICHARG" "$incar"; then
    local ich; ich="$(incar_get_val "ICHARG" "$incar" || true)"
    ich="$(echo "$ich" | awk '{print int($1)+0}')"
    if (( ich == 1 )) && [[ "$sig_src" == "$sig_dst" ]]; then
      if [[ -s "$src/CHGCAR" ]]; then
        cp -f "$src/CHGCAR" "$dst/CHGCAR"
        log "Copied CHGCAR $src → $dst"
      else
        incar_replace_same_line "ICHARG" "2" "$incar"   # same-line change
        log "CHGCAR empty/missing; set ICHARG=2 in $dst/INCAR"
      fi
    fi
  fi

  # WAVECAR only if ISTART in {1,2,3} AND structures match
  if incar_has_key "ISTART" "$incar"; then
    local ist; ist="$(incar_get_val "ISTART" "$incar" || true)"
    ist="$(echo "$ist" | awk '{print int($1)+0}')"
    if (( ist>=1 && ist<=3 )) && [[ "$sig_src" == "$sig_dst" ]]; then
      [[ -f "$src/WAVECAR" ]] && cp -f "$src/WAVECAR" "$dst/WAVECAR" || true
      [[ -f "$dst/WAVECAR" ]] && log "Copied WAVECAR $src → $dst" || log "No WAVECAR copied for $dst"
    fi
  fi
}

apply_spin_logic_if_needed() {
  # If --spin and INCAR has ISPIN=2: delete it for even NELECT, keep for odd.
  local dst="$1" nelect="$2"
  $SPIN_MODE || return 0
  local incar="$dst/INCAR"
  if incar_has_key "ISPIN" "$incar"; then
    local isp; isp="$(incar_get_val "ISPIN" "$incar" || true)"
    isp="$(echo "$isp" | awk '{print int($1)+0}')"
    if (( isp == 2 )); then
      local ne_int; ne_int="$(awk -v n="$nelect" 'BEGIN{printf "%d\n", n+0.5}')"
      if (( ne_int % 2 == 0 )); then
        incar_delete_line_key "ISPIN" "$incar"
        log "Removed ISPIN=2 (even NELECT=$ne_int) in $dst/INCAR"
      else
        log "Retained ISPIN=2 (odd NELECT) in $dst/INCAR"
      fi
    fi
  fi
}

###############################################################################
# Workflows: initial (create charges) vs continuation (final/static)
###############################################################################

prepare_initial_create_charged() {
  # Create new charged states from neutrals in NEUTRAL_ROOT.
  local bases=()
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    local name="${d##*/}"
    [[ "$name" =~ _0$ ]] || continue
    bases+=("${name%_0}")
  done < <(find "$NEUTRAL_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort)

  ((${#bases[@]})) || die "No *_0 neutral directories found under $NEUTRAL_ROOT"
  log "Discovered neutral bases: ${bases[*]}"

  for base in "${bases[@]}"; do
    local nd="$NEUTRAL_ROOT/${base}_0"

    # Compute NELECT(neutral)
    local npos npot nne
    npos="$(prefer_contcar_or_poscar "$nd")"
    npot="$(choose_file "POTCAR" "$nd")"
    nne="$(nelect_from_potcar_poscar "$npot" "$npos")"
    [[ -n "$nne" ]] || die "Failed to compute NELECT(neutral) for $nd"
    log "Base $base: NELECT(neutral)=$nne"

    for q in "${CHARGES[@]}"; do
      [[ "$q" != "0" ]] || continue
      local new="${base}_${q}"
      log "Creating $new from $nd"
      copy_inputs_from "$nd" "$new"

      # Set NELECT = neutral - q
      local newe; newe="$(awk -v n="$nne" -v qq="$q" 'BEGIN{printf "%.6f\n", (n+0)-(qq+0)}')"
      incar_set_or_append "NELECT" "$newe" "$new/INCAR"
      log "Set NELECT=$newe for $new"

      # Handle ICHARG=1 w.r.t CHGCAR presence (same-line edit if needed)
      copy_density_if_safe_or_forced "$nd" "$new"

      # Spin logic based on NELECT parity
      apply_spin_logic_if_needed "$new" "$newe"

      CREATED_JOBS+=("$new")
    done
  done
}

prepare_continuation_from_source() {
  # Continue runs from SOURCE_ROOT into PWD, honoring -Q/-N filters.
  local sel=()

  log "Scanning $SOURCE_ROOT for subdirectories (one level)…"
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue          # $d is a FULL path
    local name="${d##*/}"              # basename
    # Verbose discovery logging:
    if $CHARGED_ONLY; then
      if [[ "$name" =~ _[-+]?[0-9]+$ ]]; then
        log "Include (charged-only): $name"
        sel+=("$name")
      else
        log "Skip (charged-only, not charged): $name"
      fi
    elif $NEUTRAL_ONLY; then
      if [[ "$name" =~ _0$ ]]; then
        log "Include (neutral-only): $name"
        sel+=("$name")
      else
        log "Skip (neutral-only, not _0): $name"
      fi
    else
      if [[ "$name" =~ _0$ || "$name" =~ _[-+]?[0-9]+$ ]]; then
        log "Include (all): $name"
        sel+=("$name")
      else
        log "Skip (not matching pattern): $name"
      fi
    fi
  done < <(find "$SOURCE_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort)

  ((${#sel[@]})) || die "No matching directories under $SOURCE_ROOT"
  log "Discovered sources: ${sel[*]}"

  for name in "${sel[@]}"; do
    local src="$SOURCE_ROOT/$name"
    local dst="./$name"
    log "Preparing continuation: $name"
    copy_inputs_from "$src" "$dst"
    copy_density_if_safe_or_forced "$src" "$dst"

    # if charged dir, ensure NELECT is set/consistent
    local q; q="$(get_dir_charge_suffix "$name")"
    if [[ -n "$q" && "$q" != "0" ]]; then
      local ne; ne="$(extract_nelect_last_outcar "$src/OUTCAR" || true)"
      if [[ -z "$ne" ]]; then
        local base="${name%_*}"
        local nd="$NEUTRAL_ROOT/${base}_0"
        local npos npot nne
        npos="$(prefer_contcar_or_poscar "$nd")"
        npot="$(choose_file "POTCAR" "$nd")"
        nne="$(nelect_from_potcar_poscar "$npot" "$npos")"
        [[ -n "$nne" ]] || die "Cannot derive NELECT for $name"
        ne="$(awk -v n="$nne" -v qq="$q" 'BEGIN{printf "%.6f\n", (n+0)-(qq+0)}')"
      fi
      incar_set_or_append "NELECT" "$ne" "$dst/INCAR"
      log "Set/confirmed NELECT=$ne for $dst (charge=$q)"
      apply_spin_logic_if_needed "$dst" "$ne"
    else
      # Neutral: still apply spin logic if requested
      local maybe_ne
      if incar_has_key "NELECT" "$dst/INCAR"; then
        maybe_ne="$(incar_get_val "NELECT" "$dst/INCAR")"
        apply_spin_logic_if_needed "$dst" "$maybe_ne"
      fi
    fi

    CREATED_JOBS+=("$name")
  done
}

###############################################################################
# Submission control
###############################################################################

submit_job() { ( cd "$1" && qsub job.vasp6 ); }

decide_and_submit_jobs() {
  if ! $SUBMIT; then
    log "Dry-run (-q): no submissions. Created: ${CREATED_JOBS[*]}"
    return
  fi

  JOBS_TO_SUBMIT=()

  case "$SAFETY" in
    0)
      log "Safety=0: submitting ALL created jobs (ignoring checks)"
      JOBS_TO_SUBMIT=("${CREATED_JOBS[@]}")
      ;;
    1)
      log "Safety=1: submitting ONLY jobs that passed safety checks"
      for j in "${CREATED_JOBS[@]}"; do
        [[ -z "${JOB_UNSAFE_REASON[$j]:-}" ]] && JOBS_TO_SUBMIT+=("$j")
      done
      ;;
    2)
      if (( ${#JOB_UNSAFE_REASON[@]} > 0 )); then
        log "Safety=2: at least one job failed checks → submitting NONE"
        JOBS_TO_SUBMIT=()
      else
        log "Safety=2: all jobs safe → submitting ALL"
        JOBS_TO_SUBMIT=("${CREATED_JOBS[@]}")
      fi
      ;;
  esac

  for j in "${JOBS_TO_SUBMIT[@]}"; do
    log "Submitting: $j"
    submit_job "$j"
  done
}

perform_safety_checks_all() {
  # Always run safety checks to collect reasons (even if SAFETY=0, we still log).
  for j in "${CREATED_JOBS[@]}"; do
    if safety_check_job "$j"; then
      log "Safe: $j"
    else
      log "Unsafe: $j :: ${JOB_UNSAFE_REASON[$j]}"
    fi
  done
}

print_summary() {
  echo ""
  echo "──────────────── Summary ────────────────"
  echo "Created: ${#CREATED_JOBS[@]}"
  ((${#CREATED_JOBS[@]})) && printf '  %s\n' "${CREATED_JOBS[@]}"

  if (( ${#JOB_UNSAFE_REASON[@]} > 0 )); then
    echo ""
    echo "Unsafe jobs (not submitted under safety=1/2):"
    for j in "${!JOB_UNSAFE_REASON[@]}"; do
      echo "  $j  ::  ${JOB_UNSAFE_REASON[$j]}"
    done
  fi

  echo ""
  if $SUBMIT; then
    echo "Submission policy: safety=$SAFETY"
    echo "Submitted: ${#JOBS_TO_SUBMIT[@]}"
    ((${#JOBS_TO_SUBMIT[@]})) && printf '  %s\n' "${JOBS_TO_SUBMIT[@]}"
  else
    echo "Dry-run: no jobs submitted (-q)"
  fi
  echo "Logs: $(realpath "$LOG_FILE")"
  echo "─────────────────────────────────────────"
}

###############################################################################
# Main
###############################################################################

main() {
  parse_args "$@"
  log_init
  log "=== Starting VASP_helper ==="
  log "Mode=$MODE Stage=${STAGE:-none} Safety=$SAFETY Submit=$SUBMIT Spin=$SPIN_MODE Verbose=$VERBOSE"
  log "SOURCE_ROOT=$SOURCE_ROOT  NEUTRAL_ROOT=$NEUTRAL_ROOT"

  if [[ "$MODE" == "relax" && "$STAGE" == "initial" ]]; then
    log "Workflow: Create charged states from neutrals"
    prepare_initial_create_charged
  else
    log "Workflow: Continue existing runs (final/static)"
    prepare_continuation_from_source
  fi

  log "Prepared ${#CREATED_JOBS[@]} job directories. Beginning safety checks…"
  perform_safety_checks_all
  decide_and_submit_jobs
  log "=== VASP_helper completed ==="
  print_summary
}

main "$@"
