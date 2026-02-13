#!/usr/bin/env bash

# copyright (c) 2026 Brian Kyanjo
#  installs PETSC for firedrake into a determinstic prefix and writed out an env snippet that spack packages
# can use.
set -euo pipefail

# -----------------------
# 0) Modules (clean slate)
# -----------------------
module purge || true
# module load gcc/12.3.0   || true
# module load openmpi/4.1.5 || true
# module load python/3.11.9 || true
# module load ninja/1.12.1  || true

# spack load the required modules (if spack is available)
spack load gcc || true
spack load openmpi || true
spack load python || true
spack load ninja || true

echo "Python: $(python3 --version)"
echo "mpicc:  $(command -v mpicc || echo not-found)"
echo "mpicxx: $(command -v mpicxx || echo not-found)"
echo "mpifort:$(command -v mpifort || echo not-found)"
echo

# -----------------------
# 1) firedrake-configure (only to get PETSc version)
# -----------------------
curl -L -o firedrake-configure \
  https://raw.githubusercontent.com/firedrakeproject/firedrake/main/scripts/firedrake-configure
chmod +x firedrake-configure


PETSC_VERSION="$(python3 ./firedrake-configure --no-package-manager --show-petsc-version)"
echo "Using PETSc version: ${PETSC_VERSION}"
# -----------------------
# 2) Choose install prefix
# -----------------------
ROOT="$(pwd)"
PETSC_PREFIX="${PETSC_PREFIX:-$ROOT/externals/petsc-${PETSC_VERSION}}"
PETSC_ARCH="arch-firedrake-default"

mkdir -p "${PETSC_PREFIX}"

# -----------------------
# 3) Fetch PETSc source
# -----------------------
if [[ ! -d petsc-src ]]; then
  git clone --branch "${PETSC_VERSION}" https://gitlab.com/petsc/petsc.git petsc-src
fi

pushd petsc-src

# Fresh build dir inside source tree (PETSc style)
rm -rf "${PETSC_ARCH}"

# -----------------------
# 4) Configure + build + install
# -----------------------
./configure \
  PETSC_ARCH="${PETSC_ARCH}" \
  --prefix="${PETSC_PREFIX}" \
  --with-debugging=0 \
  --with-shared-libraries=1 \
  --with-fortran-bindings=0 \
  --with-c2html=0 \
  COPTFLAGS=-O2 CXXOPTFLAGS=-O2 FOPTFLAGS=-O2 \
  CC=mpicc CXX=mpicxx FC=mpifort \
  --download-fblaslapack=1

make -j "$(nproc)" PETSC_DIR="$PWD" PETSC_ARCH="${PETSC_ARCH}" all
make -j "$(nproc)" PETSC_DIR="$PWD" PETSC_ARCH="${PETSC_ARCH}" check

# Install to prefix
make PETSC_DIR="$PWD" PETSC_ARCH="${PETSC_ARCH}" install

popd

# -----------------------
# 5) Emit env for downstream builds (Spack uses this info)
# -----------------------
cat > "${PETSC_PREFIX}/petsc-env.sh" <<EOF
# Source this when building petsc4py/Firedrake against this PETSc
export PETSC_DIR="${PETSC_PREFIX}"
export PETSC_ARCH=""
# Use the same MPI wrappers used to build PETSc
export CC=mpicc
export CXX=mpicxx
export FC=mpifort
EOF

echo
echo "[OK] PETSc installed to: ${PETSC_PREFIX}"
echo "[OK] Env snippet: ${PETSC_PREFIX}/petsc-env.sh"