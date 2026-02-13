#!/usr/bin/env python3
# copyright (c) 2026 Brian Kyanjo
#  installs firedrake into the spack python environment using pip, with some sanity checks
import os
import subprocess
import sys
from pathlib import Path

def run(cmd, env=None):
    print(f"[install_firedrake] $ {' '.join(cmd)}", flush=True)
    subprocess.check_call(cmd, env=env)

def which(exe):
    from shutil import which as _which
    return _which(exe)

def main():
    # --- Inputs (set these in install.sh before calling) ---
    petsc_dir = os.environ.get("PETSC_DIR", "").strip()          # optional but recommended
    openmpi_prefix = os.environ.get("OPENMPI_PREFIX", "").strip() # recommended
    constraints = os.environ.get("PIP_CONSTRAINT", "").strip()    # optional
    pip_extra = os.environ.get("FIREDRAKE_PIP_ARGS", "").strip()  # optional

    env = os.environ.copy()

    # Ensure OpenMPI wrappers are found first (mpicc/mpicxx/mpifort)
    if openmpi_prefix:
        env["PATH"] = f"{openmpi_prefix}/bin:" + env.get("PATH", "")
        env["LD_LIBRARY_PATH"] = f"{openmpi_prefix}/lib:" + env.get("LD_LIBRARY_PATH", "")

    # PETSc location (if you built external PETSc)
    if petsc_dir:
        env["PETSC_DIR"] = petsc_dir
        # For installed PETSc prefix, PETSC_ARCH should be empty
        env.setdefault("PETSC_ARCH", "")

    # If pip build isolation causes numpy/cython mismatches, disable it
    env.setdefault("PIP_NO_BUILD_ISOLATION", "1")

    # Sanity checks
    for exe in ["python", "pip"]:
        if which(exe) is None:
            print(f"[install_firedrake][ERROR] missing {exe} in PATH", file=sys.stderr)
            sys.exit(1)

    for exe in ["mpicc", "mpicxx"]:
        if which(exe) is None:
            print(f"[install_firedrake][ERROR] missing {exe} (MPI wrappers not found). "
                  f"Did OPENMPI_PREFIX get exported?", file=sys.stderr)
            sys.exit(1)

    print("[install_firedrake] Python:", sys.version.replace("\n", " "))
    run([sys.executable, "-m", "pip", "--version"], env=env)

    # Make sure h5py is already present (from Spack)
    run([sys.executable, "-c", "import h5py; import numpy; print('h5py OK', h5py.__version__)"], env=env)

    # Install firedrake WITHOUT dependency resolution (Spack owns deps)
    cmd = [sys.executable, "-m", "pip", "install", "--no-deps", "firedrake[check]"]
    run(cmd, env=env)

    run(["firedrake-check"], env=env)

    # Run Firedrake check
    run(["firedrake-check"], env=env)

    print("[install_firedrake] OK")

if __name__ == "__main__":
    main()