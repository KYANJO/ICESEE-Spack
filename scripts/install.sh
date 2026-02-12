#!/usr/bin/env bash
# Copyright (c) 2026 Brian Kyanjo
set -euo pipefail

PIP_ONLY=0
for arg in "$@"; do
  [[ "$arg" == "--pip-only" ]] && PIP_ONLY=1
done

WITH_ISSM=0
for arg in "$@"; do
  [[ "$arg" == "--with-issm" ]] && WITH_ISSM=1
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ENV_DIR="${ROOT}"                         # spack.yaml is in repo root
ENV_DIR="${ROOT}/.spack-env/icesee"
# CUSTOM_REPO="${ROOT}/icesee-spack"         # contains repo.yaml + packages/
CUSTOM_REPO_REL="${ROOT}/icesee-spack"
CUSTOM_REPO="$(cd "${CUSTOM_REPO_REL}" && pwd)"   # ABSOLUTE path
ICESEE_SUBMODULE="${ROOT}/ICESEE"          # pinned ICESEE source (optional)
JOBS="${JOBS:-8}"

msg(){ echo "[ICESEE-Spack] $*"; }
die(){ echo "[ICESEE-Spack][ERROR] $*" >&2; exit 1; }

# ---- user-configurable install prefix (NO hardcoded cluster paths) ----
ICESEE_SPACK_PREFIX="${ICESEE_SPACK_PREFIX:-$ROOT/.icesee-spack/opt/spack}"
ICESEE_SPACK_CACHE="${ICESEE_SPACK_CACHE:-$ROOT/.icesee-spack/cache}"

# GCC + OpenMPI build knobs (can be overridden by environment variables)
WANT_GCC="${WANT_GCC:-13}"
MODULE_GCC="${MODULE_GCC:-gcc/${WANT_GCC}}"
OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.7}"
OPENMPI_PREFIX="${OPENMPI_PREFIX:-$ROOT/.icesee-spack/externals/openmpi-${OPENMPI_VERSION}}"
SLURM_DIR="${SLURM_DIR:-}"
PMIX_DIR="${PMIX_DIR:-}"
ICESEE_EXTERNALS_ROOT="${ICESEE_EXTERNALS_ROOT:-$ROOT/.icesee-spack/externals}"
OPENMPI_PREFIX="${OPENMPI_PREFIX:-$ICESEE_EXTERNALS_ROOT/openmpi-${OPENMPI_VERSION}}"

# ---- after OpenMPI is built/ensured ----
OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.7}"
ICESEE_EXTERNALS_ROOT="${ICESEE_EXTERNALS_ROOT:-$ROOT/.icesee-spack/externals}"
OPENMPI_PREFIX="${OPENMPI_PREFIX:-$ICESEE_EXTERNALS_ROOT/openmpi-${OPENMPI_VERSION}}"

# detect actual compiler used for your environment (gcc path/version)
GCC_BIN="${GCC_BIN:-$(command -v gcc)}"
GCC_VER="$("$GCC_BIN" -dumpfullversion -dumpversion 2>/dev/null | head -n1)"
GCC_SPEC="gcc@${GCC_VER}"

msg "Registering OpenMPI external (env-scoped) ..."
mkdir -p "${ENV_DIR}/spack"

msg "Registering OpenMPI external (env-scoped) ..."

ENV_CFG_DIR="${ENV_DIR}/spack"
mkdir -p "${ENV_CFG_DIR}"

ENV_PACKAGES_YAML="${ENV_CFG_DIR}/packages.yaml"

cat > "${ENV_PACKAGES_YAML}" <<EOF
packages:
  mpi:
    buildable: false
    providers:
      mpi: [openmpi]

  openmpi:
    buildable: false
    externals:
    - spec: openmpi@${OPENMPI_VERSION} %${GCC_SPEC}
      prefix: ${OPENMPI_PREFIX}
EOF

# hard check + debug print
[[ -f "${ENV_PACKAGES_YAML}" ]] || die "packages.yaml was not created at ${ENV_PACKAGES_YAML}"
msg "Wrote ${ENV_PACKAGES_YAML}:"
ls -l "${ENV_PACKAGES_YAML}"
sed -n '1,120p' "${ENV_PACKAGES_YAML}"
mkdir -p "${ROOT}/spack"

cat > "${ROOT}/spack/packages.yaml" <<EOF
packages:
  openmpi:
    buildable: false
    externals:
    - spec: openmpi@${OPENMPI_VERSION}
      prefix: ${OPENMPI_PREFIX}

  mpi:
    buildable: false
    providers:
      mpi: [openmpi]
EOF

# if [[ "$PIP_ONLY" -eq 0 ]]; then
# Avoid ~/.spack conflicts unless user explicitly wants them
export SPACK_DISABLE_LOCAL_CONFIG="${SPACK_DISABLE_LOCAL_CONFIG:-1}"
export SPACK_USER_CONFIG_PATH="${SPACK_USER_CONFIG_PATH:-$ROOT/.spack-user-empty}"
mkdir -p "$SPACK_USER_CONFIG_PATH"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# 0) Ensure git submodules exist
if [[ -d "${ROOT}/.git" ]]; then
  msg "Updating submodules..."
  git -C "${ROOT}" submodule update --init --recursive
fi

# 1) Choose Spack: system first, else pinned submodule
if command -v spack >/dev/null 2>&1; then
  msg "Using system Spack: $(command -v spack)"
  SPACK_BIN="spack"
else
  [[ -f "${ROOT}/spack/share/spack/setup-env.sh" ]] || die "No system spack and no ./spack submodule"
  msg "Using pinned Spack submodule: ${ROOT}/spack"
  # shellcheck disable=SC1091
  source "${ROOT}/spack/share/spack/setup-env.sh"
  SPACK_BIN="spack"
fi

# Prefer not to inherit random local config unless user wants it
SPACK_CMD="${SPACK_BIN} --no-local-config"

mkdir -p "${ENV_DIR}"

# Copy the repo-root spack.yaml into the environment dir (source of truth stays in repo)
cp -f "${ROOT}/spack.yaml" "${ENV_DIR}/spack.yaml"

# 2) Ensure required repo/env files exist
[[ -f "${ENV_DIR}/spack.yaml" ]] || die "spack.yaml not found at ${ENV_DIR}/spack.yaml"
[[ -f "${CUSTOM_REPO}/repo.yaml" ]] || die "repo.yaml not found at ${CUSTOM_REPO}/repo.yaml"
[[ -d "${CUSTOM_REPO}/packages" ]] || die "custom repo missing ${CUSTOM_REPO}/packages"

# 3) Create env-scoped config (generic prefix/cache paths)
ENV_CFG_DIR="${ENV_DIR}/spack"
mkdir -p "${ENV_CFG_DIR}"

cat > "${ENV_CFG_DIR}/config.yaml" <<EOF
config:
  install_tree:
    root: ${ICESEE_SPACK_PREFIX}
  build_stage:
  - ${ICESEE_SPACK_CACHE}/stage
  misc_cache: ${ICESEE_SPACK_CACHE}/misc
  source_cache: ${ICESEE_SPACK_CACHE}/source
EOF

# 4) Toolchain selection: module gcc/13 -> else spack install/load gcc@13 -> else system gcc
msg "Ensuring GCC >= ${WANT_GCC}..."
if have_cmd module; then
  if module -t avail 2>&1 | grep -qx "${MODULE_GCC}"; then
    msg "Loading module ${MODULE_GCC}"
    module load "${MODULE_GCC}"
  else
    msg "Module ${MODULE_GCC} not available"
    # load general gcc for spack install gcc@${WANT_GCC} (if available); if not, spack will build it from source
    module load gcc || msg "No gcc module available; relying on system compiler for Spack builds (may fail if too old)"
  fi
fi

gcc_major="$(gcc -dumpversion 2>/dev/null | cut -d. -f1 || echo 0)"
if [[ "${gcc_major}" -lt "${WANT_GCC}" ]]; then
  msg "gcc>=${WANT_GCC} not found (current major=${gcc_major}). Installing gcc@${WANT_GCC} via Spack..."

  # Find compilers in isolated config scope (does NOT need env scope)
  # $SPACK_CMD compiler find --scope user || true
  $SPACK_CMD compiler find || true

  if ! $SPACK_CMD find "gcc@${WANT_GCC}" 2>/dev/null | grep -q "gcc@${WANT_GCC}"; then
    $SPACK_CMD install -j "${JOBS}" "gcc@${WANT_GCC}"
  fi

  # Load installed gcc so subsequent builds use it
  $SPACK_CMD load "gcc@${WANT_GCC}"
  # $SPACK_CMD compiler find --scope user || true
  $SPACK_CMD compiler find || true
fi

have_cmd gcc || die "gcc not found after attempting module/spack setup"
have_cmd g++ || die "g++ not found after attempting module/spack setup"
have_cmd gfortran || die "gfortran not found after attempting module/spack setup"
msg "Using gcc: $(command -v gcc) ($(gcc --version | head -n1))"

# 5) Add custom Spack repo (idempotent)
# msg "Adding custom Spack repo..."
# $SPACK_CMD -e "${ENV_DIR}" repo add "${CUSTOM_REPO}" || true
msg "Adding custom Spack repo (absolute path, env-scoped)..."

# Remove stale mapping if it exists (especially if it was ./icesee-spack)
$SPACK_CMD -e "${ENV_DIR}" config rm repos:icesee >/dev/null 2>&1 || true

# Add repo with absolute path (this creates repos: {icesee: /abs/path})
$SPACK_CMD -e "${ENV_DIR}" repo add "${CUSTOM_REPO}"

# Sanity check: Spack can see the repo.yaml
if ! $SPACK_CMD -e "${ENV_DIR}" config get repos | grep -q "${CUSTOM_REPO}"; then
  msg "WARNING: repo path not showing as absolute in env config. Dumping repos:"
  $SPACK_CMD -e "${ENV_DIR}" config get repos
  die "Custom repo registration failed (expected absolute path)."
fi

# 6) Ensure OpenMPI exists at OPENMPI_PREFIX (build if missing)
msg "Ensuring OpenMPI ${OPENMPI_VERSION} at ${OPENMPI_PREFIX}..."
export OPENMPI_VERSION OPENMPI_PREFIX JOBS MODULE_GCC SLURM_DIR PMIX_DIR
export SPACK_CMD="$SPACK_CMD"        # you already have it
export SPACK_GCC_SPEC="gcc@${WANT_GCC}"
"${ROOT}/scripts/build_openmpi.sh"

# 7) Register OpenMPI as a Spack external for THIS environment (so concretize stops failing)
#    This avoids the "Cannot satisfy openmpi@5.0.7" / node_os weirdness from stale external configs.
msg "Registering OpenMPI external in env packages.yaml..."

ENV_PACKAGES_YAML="${ENV_CFG_DIR}/packages.yaml"
gcc_ver_full="$(gcc -dumpfullversion -dumpversion 2>/dev/null || true)"
gcc_spec="gcc@${gcc_ver_full:-${WANT_GCC}}"

cat > "${ENV_PACKAGES_YAML}" <<EOF
packages:
  all:
    compiler: [${gcc_spec}]
  mpi:
    buildable: false
    providers:
      mpi: [openmpi]
  openmpi:
    buildable: false
    externals:
    - spec: openmpi@${OPENMPI_VERSION}%${gcc_spec}
      prefix: ${OPENMPI_PREFIX}
EOF

# 8) Concretize + install
msg "Checking custom package is visible (py-icesee)..."
$SPACK_CMD -e "${ENV_DIR}" info py-icesee >/dev/null 2>&1 || {
  msg "Repo list:"
  $SPACK_CMD -e "${ENV_DIR}" repo list
  msg "Repos config:"
  $SPACK_CMD -e "${ENV_DIR}" config get repos
  die "py-icesee not visible to Spack (repo.yaml/path problem)."
}
msg "Concretizing..."
$SPACK_CMD -e "${ENV_DIR}" concretize -f

msg "Installing (-j ${JOBS})..."
$SPACK_CMD -e "${ENV_DIR}" install -j "${JOBS}"

# 9) Develop ICESEE from pinned submodule (so spack uses your source), if present
if [[ -f "${ICESEE_SUBMODULE}/pyproject.toml" ]]; then
  msg "Registering ICESEE submodule for develop install..."
  $SPACK_CMD -e "${ENV_DIR}" develop --path "${ICESEE_SUBMODULE}" py-icesee@main || true

  msg "Reinstalling py-icesee from local source..."
  $SPACK_CMD -e "${ENV_DIR}" install -f py-icesee@main
else
  msg "WARNING: ${ICESEE_SUBMODULE}/pyproject.toml not found; skipping develop install."
fi

# 10) Regenerate view (safe even if view:false)
# msg "Regenerating view..."
# $SPACK_CMD -e "${ENV_DIR}" view regenerate || true
msg "Skipping Spack view (view: false)."
# fi

# 11) Use env python WITHOUT requiring shell activation
PYTHON="$($SPACK_CMD -e "${ENV_DIR}" location -i python)/bin/python"
msg "Ensuring pip is available in Spack Python..."
"$PYTHON" -m pip --version >/dev/null 2>&1 || {
  msg "pip missing; bootstrapping via ensurepip..."
  "$PYTHON" -m ensurepip --upgrade || true
  "$PYTHON" -m pip install --upgrade pip setuptools wheel
}
[[ -x "${PYTHON}" ]] || die "Could not locate env python via Spack"

# 12) Generate pip-only requirements from ICESEE/pyproject.toml and install them
PYPROJECT="${ICESEE_SUBMODULE}/pyproject.toml"
PIP_REQS="${ROOT}/requirements/pip.auto.txt"

if [[ -f "${PYPROJECT}" ]]; then
  msg "Generating pip requirements from ICESEE pyproject.toml..."
  "${PYTHON}" "${ROOT}/scripts/gen_pip_reqs.py" \
    --pyproject "${PYPROJECT}" \
    --out "${PIP_REQS}" \
    --extras "mpi,viz"

  msg "Installing pip-only deps..."
  "${PYTHON}" -m pip install -U pip setuptools wheel
  "${PYTHON}" -m pip install --no-cache-dir -r "${PIP_REQS}"
else
  msg "WARNING: ${PYPROJECT} not found; skipping pip-only dependency generation."
fi

# 12.1)
if [[ "${WITH_ISSM}" -eq 1 ]]; then
  msg "Installing ISSM (--with-issm enabled)..."
  export ICESEE_EXTERNALS_ROOT="${ICESEE_EXTERNALS_ROOT:-$ROOT/.icesee-spack/externals}"
  export ISSM_PREFIX="${ISSM_PREFIX:-$ICESEE_EXTERNALS_ROOT/ISSM}"
  export MODULE_GCC="${MODULE_GCC:-gcc/${WANT_GCC:-13}}"
  export MODULE_MATLAB="${MODULE_MATLAB:-matlab}"
  # MATLABROOT should come from module load; user can also export it manually
  # "${ROOT}/scripts/build_issm.sh"
  # bash "${ROOT}/scripts/build_issm.sh" "${OPENMPI_PREFIX}"
  ISSM_DIR="${ISSM_DIR:-$ICESEE_EXTERNALS_ROOT/ISSM}"
  export ISSM_DIR
  export OPENMPI_PREFIX
  bash "${ROOT}/scripts/build_issm.sh"
else
  msg "Skipping ISSM install (use --with-issm to enable)."
fi


# 13) Smoke tests
msg "Running smoke tests..."
# Keep your existing behavior: if scripts/test.sh is a shell script, run via bash
if [[ -f "${ROOT}/scripts/test.sh" ]]; then
  msg "Running ${ROOT}/scripts/test.sh... to test Spack environment and py-icesee installation"
  bash "${ROOT}/scripts/test.sh"
  if [[ "$WITH_ISSM" -eq 1 ]]; then
    msg "Running ${ROOT}/scripts/test_issm.sh... to test ISSM installation (if --with-issm enabled)"
    bash "${ROOT}/scripts/test_issm.sh"
  fi
else
  msg "WARNING: scripts/test.sh not found; skipping tests."
fi

msg "Install complete."
msg "Prefix: ${ICESEE_SPACK_PREFIX}"
msg "OpenMPI: ${OPENMPI_PREFIX}"
msg "To use the environment:"
msg "  eval \"\$(${SPACK_BIN} -e ${ENV_DIR} env activate --sh)\""

