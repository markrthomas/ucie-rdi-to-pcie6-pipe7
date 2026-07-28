#!/usr/bin/env bash
#
# gen_cocotb_icarus_bin.sh <outdir>
#
# Generate an ICARUS_BIN_DIR (iverilog + vvp shims) so cocotb can run on Icarus Verilog as the
# INDEPENDENT simulation engine (Phase G -- redundant functional-coverage cross-check to the
# Verilator line union).
#
# Why this is needed: the oss-cad-suite `vvp` on PATH is a wrapper script that force-exports
# PYTHONHOME/PYTHONEXECUTABLE to its own bundled interpreter (tabbypy3), which has no cocotb and
# no matching stdlib -- so cocotb's embedded Python crashes with "No module named 'encodings'".
# We emit a `vvp` shim that runs the SAME oss-cad-suite vvp binary (via its bundled ld-linux, so
# the Icarus runtime libs still resolve) but points PYTHONHOME/LIBPYTHON_LOC at the system Python
# that actually has cocotb + cocotb_coverage installed. `iverilog` (compile only, no Python) is a
# plain pass-through.
#
# If the `vvp` on PATH is NOT the oss-cad-suite wrapper (e.g. a distro iverilog that respects the
# ambient environment), no shim is needed and we just symlink through.
set -euo pipefail

OUT=${1:?usage: gen_cocotb_icarus_bin.sh <outdir>}
mkdir -p "$OUT"

realvvp=$(command -v vvp 2>/dev/null) || { echo "gen_cocotb_icarus_bin: no vvp on PATH" >&2; exit 1; }
realiv=$(command -v iverilog 2>/dev/null) || { echo "gen_cocotb_icarus_bin: no iverilog on PATH" >&2; exit 1; }

pybin=$(cocotb-config --python-bin)
libpy=$(cocotb-config --libpython)
libdir=$(dirname "$libpy")
pyhome=$("$pybin" -c 'import sys; print(sys.base_prefix)')

if grep -q "libexec/vvp" "$realvvp" 2>/dev/null; then
    # oss-cad-suite wrapper: rebuild its exec line, but with the system cocotb Python.
    top=$(readlink -f "$(dirname "$realvvp")/..")
    cat > "$OUT/iverilog" <<EOF
#!/usr/bin/env bash
exec "$top/bin/iverilog" "\$@"
EOF
    cat > "$OUT/vvp" <<EOF
#!/usr/bin/env bash
# cocotb-on-icarus: run oss-cad-suite's vvp binary with the system (cocotb-enabled) Python.
export PYTHONHOME="$pyhome"
export PYTHONEXECUTABLE="$pybin"
export LIBPYTHON_LOC="$libpy"
exec "$top/lib/ld-linux-x86-64.so.2" --inhibit-cache --inhibit-rpath "" \\
     --library-path "$top/lib:$libdir" \\
     "$top/libexec/vvp" "\$@"
EOF
    chmod +x "$OUT/iverilog" "$OUT/vvp"
    echo "gen_cocotb_icarus_bin: wrote oss-cad-suite shim in $OUT (Python -> $pybin)"
else
    # Non-oss-cad-suite iverilog: ambient environment already correct, pass straight through.
    ln -sf "$realiv" "$OUT/iverilog"
    ln -sf "$realvvp" "$OUT/vvp"
    echo "gen_cocotb_icarus_bin: linked plain iverilog/vvp in $OUT (no shim needed)"
fi
