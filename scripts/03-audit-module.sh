#!/usr/bin/env bash
# =============================================================================
# Audit the freshly built v3.3.0 dm3q module against the recovered FZG1
# vmlinux. Only "missing from target symbol table" is a hard failure:
# symbols resolved through kallsyms (non-exported) and CRC mismatches are
# expected for Samsung kernels - the late-load manual-relocation loader
# resolves every undefined symbol from /proc/kallsyms, so the kernel never
# consults exports or __versions CRCs.
#
# Usage:
#   ./03-audit-module.sh <path/to/vmlinux.elf>
# The vmlinux must be extracted from the EXACT target firmware (S9180ZHS8FZG1).
# Audit tools are fetched from upstream (Apache-2.0) on first run.
# =============================================================================
set -euo pipefail

VMLINUX="${1:?Usage: ./03-audit-module.sh <path/to/vmlinux.elf>}"
MOD="out/android13-5.15_kernelsu-dm3q-S9180ZHS8FZG1-330.ko"
TOOLS="tools"
TOOLS_UPSTREAM="https://raw.githubusercontent.com/BuSung-dev/Root-My-Galaxy-Payloads/main/kernelsu/tools"
PY="${PYTHON:-python3}"

mkdir -p "${TOOLS}"
for f in extract_target_symvers.py audit_module_against_target.py; do
    if [ ! -f "${TOOLS}/${f}" ]; then
        echo "== fetching ${f} from upstream (Apache-2.0)"
        curl -fsSL "${TOOLS_UPSTREAM}/${f}" -o "${TOOLS}/${f}"
    fi
done

[ -f "${MOD}" ] || { echo "ERROR: ${MOD} missing - run 01-build-module.sh first"; exit 1; }
[ -f "${VMLINUX}" ] || { echo "ERROR: vmlinux not found: ${VMLINUX}"; exit 1; }

echo "== modinfo"
"${PY}" - "$MOD" <<'EOF'
import struct, sys
from pathlib import Path
d = Path(sys.argv[1]).read_bytes()
e = struct.unpack_from("<16sHHIQQQIHHHHHH", d, 0)
shoff, shentsize, shnum, shstrndx = e[6], e[11], e[12], e[13]
st = struct.unpack_from("<IIQQQQIIQQ", d, shoff + shstrndx * shentsize)
strtab = d[st[4]:st[4] + st[5]]
def nm(x):
    return strtab[x:strtab.find(b"\0", x)].decode()
for i in range(shnum):
    s = struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shentsize)
    n = nm(s[0])
    if n == "__versions":
        print(f"  __versions size = {s[5]} (entries = {s[5] // 64})")
    if n == ".modinfo":
        for line in d[s[4]:s[4] + s[5]].decode(errors="replace").split("\0"):
            if line.startswith(("vermagic=", "version=")):
                print("  " + line)
EOF

echo "== reconstruct target Module.symvers from FZG1 vmlinux"
"${PY}" -m pip show pyelftools >/dev/null 2>&1 || "${PY}" -m pip install pyelftools
"${PY}" "${TOOLS}/extract_target_symvers.py" "${VMLINUX}" out/Module.symvers-fzg1
wc -l out/Module.symvers-fzg1

echo "== audit (hard gate: missing from target symbol table must be 0)"
set +e
"${PY}" "${TOOLS}/audit_module_against_target.py" "${MOD}" "${VMLINUX}" out/Module.symvers-fzg1
RC=$?
set -e

echo ""
if [ "${RC}" -ne 0 ]; then
    echo "audit tool exit=${RC}. For the late-load manual-relocation path the"
    echo "hard gate is only: 'missing from target symbol table: 0'."
    echo "MISSING_EXPORT / CRC_MISMATCH lines are acceptable (non-exported"
    echo "Samsung symbols are resolved from /proc/kallsyms at load time)."
    echo "Re-run and grep the report:"
    echo "  ${PY} ${TOOLS}/audit_module_against_target.py ${MOD} ${VMLINUX} out/Module.symvers-fzg1 | grep MISSING_SYMBOL"
    "${PY}" "${TOOLS}/audit_module_against_target.py" "${MOD}" "${VMLINUX}" out/Module.symvers-fzg1 2>/dev/null | grep -c "^MISSING_SYMBOL" | grep -q "^0$" \
        && { echo "PASS: zero symbols missing from the target symbol table"; exit 0; } \
        || { echo "FAIL: missing symbols present - DO NOT deploy"; exit 1; }
else
    echo "PASS: audit clean"
fi
