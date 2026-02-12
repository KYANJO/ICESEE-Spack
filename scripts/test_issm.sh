#!/usr/bin/env bash
set -euo pipefail

echo "[test_issm] Starting ISSM smoke test..."

# Allow user overrides
MATLAB_BIN="${MATLAB_BIN:-matlab}"
ISSM_DIR="${ISSM_DIR:-}"

# If ISSM_DIR not set, try to infer from common environment or path
if [[ -z "${ISSM_DIR}" ]]; then
  # Heuristic: if "issmversion" exists in PATH, try to locate ISSM root
  if command -v issmversion >/dev/null 2>&1; then
    ISSMVERSION_PATH="$(command -v issmversion)"
    # Often $ISSM_DIR/bin/issmversion or $ISSM_DIR/src/m/...
    # Try walking up a few levels
    CANDIDATE="$(cd "$(dirname "${ISSMVERSION_PATH}")/.." && pwd)"
    ISSM_DIR="${CANDIDATE}"
  fi
fi

echo "[test_issm] MATLAB: ${MATLAB_BIN}"
echo "[test_issm] ISSM_DIR: ${ISSM_DIR:-<not set>}"

command -v "${MATLAB_BIN}" >/dev/null 2>&1 || {
  echo "[test_issm][ERROR] MATLAB executable not found: ${MATLAB_BIN}"
  echo "[test_issm] Hint: load your MATLAB module (e.g., 'module load matlab')"
  exit 2
}

if [[ -z "${ISSM_DIR}" || ! -d "${ISSM_DIR}" ]]; then
  echo "[test_issm][ERROR] ISSM_DIR is not set or not a directory."
  echo "[test_issm] Set ISSM_DIR=/path/to/ISSM or load an ISSM module."
  exit 3
fi

# Try to source the ISSM MATLAB environment if present
# Common: $ISSM_DIR/etc/environment.sh (sets MATLABPATH additions, etc.)
if [[ -f "${ISSM_DIR}/etc/environment.sh" ]]; then
  echo "[test_issm] Sourcing ${ISSM_DIR}/etc/environment.sh"
  # shellcheck disable=SC1090
  set +u
  source "${ISSM_DIR}/etc/environment.sh"
  set -u
fi

# Minimal MATLAB call:
# - add ISSM matlab paths if needed
# - call issmversion
# - exit with nonzero on failure
TMP_MFILE="$(mktemp /tmp/icesee_issm_test_XXXX.m)"
cat > "${TMP_MFILE}" <<'EOF'
try
    disp('[test_issm] MATLAB started');
    % If ISSM_DIR is set in environment, add relevant matlab paths
    issm_dir = getenv('ISSM_DIR');
    if ~isempty(issm_dir)
        % Common MATLAB entry points in ISSM
        addpath(fullfile(issm_dir,'src','m'));
        addpath(genpath(fullfile(issm_dir,'src','m')));
    end

    if exist('issmversion','file') ~= 2
        error('issmversion not found on MATLAB path. Check ISSM_DIR and MATLAB paths.');
    end

    v = issmversion();
    disp(['[test_issm] issmversion: ', v]);

    disp('[test_issm] OK');
    exit(0);
catch ME
    disp('[test_issm][ERROR] FAILED');
    disp(getReport(ME,'extended'));
    exit(1);
end
EOF

echo "[test_issm] Running MATLAB issmversion()..."
"${MATLAB_BIN}" -nodisplay -nosplash -nodesktop -r "run('${TMP_MFILE}');"

rm -f "${TMP_MFILE}"
echo "[test_issm] Done."