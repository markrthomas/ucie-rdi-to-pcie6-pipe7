# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# Minimal, reproducible DV toolchain image (see DV_STANDARDS.md).
#
# Icarus Verilog (apt) + a pinned Verilator (oss-cad-suite) + cocotb/PyUVM (pip,
# in a venv) — enough to run this repo's `make check` (and most of its other DV
# targets) the same way in a container as on a dev box. Optional heavier tiers
# this repo may have (SymbiYosys/`make formal`, a commercial UVM simulator/
# `make uvm`, GTKWave) are NOT installed here and degrade gracefully (skip,
# exit 0) as designed.
#
# Verilator is pinned to the same oss-cad-suite build this repo's own
# .github/workflows/ci.yml uses (YosysHQ/setup-oss-cad-suite), not apt: apt's
# Ubuntu-24.04 Verilator (5.020) rejects this repo's `##[1:N]` cycle-delay-range
# SVA sequences ("Unsupported: ## range cycle delay range expression"), which
# fails `make lint`/`make regress` under `make check`.
#
# Build:  docker build -t <repo> .
# Run  :  docker run --rm <repo>            # make check (default)
#         docker run --rm <repo> make lint  # a single target
# -----------------------------------------------------------------------------
FROM ubuntu:24.04

# Pin matches the oss-cad-suite build used elsewhere in this maintainer's repo
# family (e.g. axi-on-ucie-to-mem) — bump deliberately, not "latest".
ARG OSS_TAG=2026-04-13
ARG OSS_STAMP=20260413
ARG COCOTB_VERSION=1.9.2
ARG PYUVM_VERSION=4.0.1

ENV DEBIAN_FRONTEND=noninteractive

# Force a UTF-8 locale + Python I/O encoding. A container/CI runner starts under
# a bare C/POSIX locale, which makes Python's stdout fall back to the ASCII
# codec -- printing any non-ASCII character (seen in the wild: an em-dash in a
# cocotb coverage banner) then raises UnicodeEncodeError and aborts the run.
# ubuntu:24.04 ships C.UTF-8 built in, so this needs no locale-gen.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=UTF-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        iverilog \
        build-essential \
        python3 \
        python3-dev \
        python3-venv \
        ca-certificates \
        curl \
        git \
        make \
    && rm -rf /var/lib/apt/lists/*

# --- Pinned Verilator via oss-cad-suite ---------------------------------------
# Its bin/ is put on PATH ahead of anything else so this repo's Makefile
# (`VERILATOR ?= $(shell command -v verilator_bin || command -v verilator)`)
# resolves the pinned build with no other override needed.
ENV OSS=/opt/oss-cad-suite
RUN curl -fL -o /tmp/oss.tgz \
      "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_TAG}/oss-cad-suite-linux-x64-${OSS_STAMP}.tgz" \
    && tar xzf /tmp/oss.tgz -C /opt \
    && rm /tmp/oss.tgz
ENV PATH="$OSS/bin:$PATH"

# Python deps (cocotb + pyuvm + cocotb_coverage + pytest) in an isolated venv --
# satisfies PEP 668 (Ubuntu 24.04 marks the system Python externally managed)
# and keeps the cocotb interpreter self-contained. cocotb's makefiles pick up
# `python`/`python3` from PATH.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
        "cocotb==${COCOTB_VERSION}" "pyuvm==${PYUVM_VERSION}" cocotb_coverage pytest

WORKDIR /work
COPY . /work

# Fail fast if the toolchain didn't assemble correctly.
RUN iverilog -V | head -1 \
    && verilator --version \
    && command -v verilator | grep -q "$OSS/bin" \
    && python -c "import cocotb, pyuvm, cocotb_coverage; print('cocotb', cocotb.__version__, 'pyuvm', pyuvm.__version__)"

# Default: the standard light local gate (see DV_STANDARDS.md). Override the
# command to run a different target, e.g. `docker run --rm <repo> make ci`.
CMD ["make", "check"]
