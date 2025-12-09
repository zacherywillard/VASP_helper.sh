# VASP Helper

Bash helper to prepare and continue VASP defect jobs. Allows for relaxation and static defect job submission.

It auto-detects defect directories within the specified source directory. Allows the generation of charged states from relaxed neutral defects. Performs safety checks (KPAR/CHGCAR/WAVECAR), handles spin parity (optionally removing `ISPIN=2` for even `NELECT`), and can submit jobs (`qsub`) after all checks pass. A verbose mode logs everything to `helper.log`.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Directory Convention](#directory-convention)
- [Quick Start](#quick-start)
- [Command Reference](#command-reference)
- [Workflows](#workflows)
  - [Create charged states from neutrals (relax initial)](#create-charged-states-from-neutrals-relax-initial)
  - [Continue relax (final) or run static](#continue-relax-final-or-run-static)
  - [Selectors: ](#selectors--q--n-and---charges)[`-Q`](#selectors--q--n-and---charges)[, ](#selectors--q--n-and---charges)[`-N`](#selectors--q--n-and---charges)[, and ](#selectors--q--n-and---charges)[`--charges`](#selectors--q--n-and---charges)
- [Safety Checks & Submission Policy](#safety-checks--submission-policy)
- [Spin‑Aware INCAR Handling (](#spinaware-incar-handling---spin)[`--spin`](#spinaware-incar-handling---spin)[)](#spinaware-incar-handling---spin)
- [What Gets Copied, and Overrides](#what-gets-copied-and-overrides)
- [Logging & Debugging](#logging--debugging)
- [Testing Locally (no real submission)](#testing-locally-no-real-submission)

---

## Features

- **Create charged defect states** from a neutral reference (`--mode relax --stage initial -Q`).
- **Continue** neutral and charged jobs (`--mode relax --stage final`).
- **Static** neutral and charged jobs (`--mode static`)
- **Spin parity control**: with `--spin`, if `ISPIN=2` and computed `NELECT` is **even**, the script **deletes** the `ISPIN` line; if **odd**, it is kept.
- **Safety system** with three levels:
  - `--safety 0` → ignore all checks; submit all.
  - `--safety 1` (default) → submit only jobs that pass checks.
  - `--safety 2` → if *any* job fails, submit **none**.
- **CHGCAR/WAVECAR safety**:
  - If `ICHARG=1` → `CHGCAR` must exist and be **non‑empty**; else rewrite same line to `ICHARG=2`.
  - If `ISTART ∈ {1,2,3}` → `WAVECAR` must exist.
- **Global overrides**: local `./INCAR`, `./KPOINTS`, `./POTCAR`, `./job.vasp6` override per‑defect files.
- **Verbose logs** to console and `helper.log`.

---

## Requirements

- Linux/Unix environment with Bash 4+, `awk`, `sed`, `find`.
- VASP input files: `INCAR`, `KPOINTS`, `POTCAR`, `POSCAR/CONTCAR`, `job.vasp6`.
- Queue submission via `qsub` in `PATH` (PBS/SGE).

---

## Install

```bash
# Clone and make the helper executable
git clone https://github.com/zacherywillard/VASP_helper.sh
cd VASP_helper.sh
chmod +x VASP_helper.sh
```
---

## Directory Convention

Your source root contains one level of defect directories named:

```
<defect>_<site>_<charge>
# Examples
Cd_Se_0    Se_Cd_-1    Va_Cd_2    Si_i_0
```

- **Neutral** ends with `_0`.
- **Charged** ends with `_Q`.

The script discovers these automatically in `--source_root` (and `--neutral_root` when creating charges).

---

## Quick Start

**Continue existing runs (static), all dirs under **``**:**

```bash
./VASP_helper.sh --mode static --source_root ./src --safety 1 -v
```

**Create charged states from neutrals (initial relax):**

```bash
./VASP_helper.sh --mode relax --stage initial -Q \
  --source_root ./neutrals \
  --neutral_root ./neutrals \
  --spin --safety 1 -v
```

**Dry‑run (prepare only, no submit):**

```bash
./VASP_helper.sh --mode static --source_root ./src -q -v
```

---

## Command Reference

```
--mode [relax|static]
--stage [initial|final]     # required if --mode relax
--source_root PATH          # required
--neutral_root PATH         # optional; defaults to --source_root when needed

-Q                          # charged-only
-N                          # neutral-only (invalid with relax initial)
--charges "list"            # e.g. "--charges '-2 -1 1 2'" (default: -2 -1 1 2)

--spin                      # if INCAR has ISPIN=2, delete it for even NELECT
--safety [0|1|2]            # 0=ignore checks; 1=safe-only; 2=all-or-none (default: 1)
-q                          # no-submit (dry-run)
-v, --verbose               # verbose console + helper.log
-h, --help
```

**Mutual exclusivity:** you cannot specify both `-Q` and `-N`.

**Relax initial requires:** `-Q` (charged‑only). `-N` is invalid for this stage.

---

## Workflows

### Create charged states from neutrals (relax initial)

- Discovers `*_0` under `--neutral_root`.
- For each base name (without `_0`), creates charged dirs per `--charges` (default `-2 -1 1 2`).
- Computes `NELECT(charged) = NELECT(neutral) − charge` using POSCAR (counts) + POTCAR (`ZVAL`).
- Applies `--spin` parity logic to `ISPIN`.
- Handles `ICHARG=1` (requires non‑empty `CHGCAR`; else same‑line change to `ICHARG=2`).
- Defers all submissions until **after** safety checks for all jobs.

### Continue relax (final) or run static

- Discovers subdirs in `--source_root` matching `_0` or `_Q`.
- If charged (`_Q`), derives `NELECT` from source `OUTCAR` or from neutral reference minus charge.
- Copies `CHGCAR`/`WAVECAR` only when safe/required (see Safety Checks), unless `--safety 0`.

### Selectors: `-Q`, `-N`, and `--charges`

- `-Q` selects **charged** subdirs only; `-N` selects **neutral** only.
- If neither is given, all matching subdirs are used.
- `--charges` controls which charge states are created during **relax initial**.

---

**Submission policy:**

- `0` — **ignore** checks; **submit all**.
- `1` — **submit only safe** jobs; unsafe jobs are prepared but not submitted.
- `2` — if **any** job is unsafe → **submit none**.

> The script always creates/updates the target directories first, then runs safety checks, then decides submissions.

---

## Spin‑Aware INCAR Handling (`--spin`)

If `--spin` is set and `INCAR` contains `ISPIN=2`:

- Compute/obtain job `NELECT`.
- If `NELECT` is **even** → **delete** the `ISPIN` line from `INCAR`.
- If `NELECT` is **odd** → keep `ISPIN=2`.

> This is applied per job so mixed parity across charge states is handled correctly.

---


## What Gets Copied, and Overrides

For each prepared/continued job, the script copies into the new directory:

- `POSCAR` (prefers `CONTCAR` if present),
- `INCAR`, `KPOINTS`, `POTCAR`, `job.vasp6`.

**Global overrides**: if the working directory contains `./INCAR`, `./KPOINTS`, `./POTCAR`, or `./job.vasp6`, those **override** the files from the source defect directory for **all jobs** in the current run.

**Density files** (`CHGCAR`, `WAVECAR`): copied only when required by the INCAR **and** source/target structures match (species/count signature via POSCAR line 6/7). With `--safety 0`, they are copied if they exist.

---

## Logging & Debugging

- All runs also write a timestamped log to `helper.log` in the working directory.
- The log includes: discovery decisions, computed `NELECT`, INCAR changes, safety reasons, and submission actions.

---

## Troubleshooting

- **“No matching directories under …”**

  - Ensure subdirectories follow `<defect>_<site>_<charge>` and you pointed `--source_root` at the **parent** of those.
  - For charge creation, ensure neutrals exist as `*_0` under `--neutral_root`.

- **CHGCAR safety**

  - If `ICHARG=1`, confirm `CHGCAR` exists and is **non‑empty**; otherwise the script rewrites to `ICHARG=2`.

- **WAVECAR safety**

  - If `ISTART ∈ {1,2,3}`, ensure `WAVECAR` is present.

- **Spin parity not applied**

  - `--spin` must be provided, and `INCAR` must contain `ISPIN=2` to trigger parity logic.

---

## License

MIT (or your preferred license). Add your LICENSE file to the repo root.

