"""PyUVM environment + scoreboard for the Tier 1b datapath cross-check (item 13).

The scoreboard performs a three-way cross-check on each run, so a common-mode framing bug
cannot pass silently:

  1. round-trip identity      : DUT recovered payloads == driven payloads.
  2. framer vs Python model   : the DUT's raw TxData word stream == framing_model.frame_stream
                                of the driven payloads (bit-exact, independent implementation).
  3. Python deframe vs DUT    : framing_model.deframe_stream of the DUT's own TxData stream ==
                                the DUT's recovered payloads (+ every sync header legal).

Any disagreement localizes the bug to exactly one of {DUT, SV-TB(shared model), Python-TB}.
"""
from pyuvm import uvm_env, uvm_scoreboard, uvm_tlm_analysis_fifo, ConfigDB

from agents.ucie_rdi_agent import RdiAgent
from models import framing_model as fm

PIPE_WIDTH = 80   # matches pipe7_framing_top's default parameter


def _drain(fifo):
    out = []
    while fifo.can_get():
        success, item = fifo.try_get()
        if not success:
            break
        out.append(item)
    return out


class DatapathScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.exp_fifo = uvm_tlm_analysis_fifo("exp_fifo", self)       # driven payloads
        self.act_fifo = uvm_tlm_analysis_fifo("act_fifo", self)       # recovered payloads
        self.stream_fifo = uvm_tlm_analysis_fifo("stream_fifo", self) # TxData words
        self.errors = []

    def check_phase(self):
        expected = _drain(self.exp_fifo)                 # [(data, is_os), ...]
        actual = _drain(self.act_fifo)                   # [(data, is_os), ...]
        stream = _drain(self.stream_fifo)                # [word, ...]

        # 1. round-trip identity
        if actual != expected:
            n = min(len(actual), len(expected))
            first = next((i for i in range(n) if actual[i] != expected[i]), n)
            self.errors.append(
                f"round-trip mismatch: {len(actual)} recovered vs {len(expected)} driven; "
                f"first diff at #{first}")

        # 2. DUT framer stream == independent Python framer
        model_stream = fm.frame_stream(expected, PIPE_WIDTH)
        if stream != model_stream:
            n = min(len(stream), len(model_stream))
            first = next((i for i in range(n) if stream[i] != model_stream[i]), n)
            self.errors.append(
                f"framer/model stream mismatch: {len(stream)} DUT words vs "
                f"{len(model_stream)} model words; first diff at word #{first}")

        # 3. independent Python deframe of the DUT's own stream == DUT recovered payloads
        model_out = fm.deframe_stream(stream, PIPE_WIDTH, len(expected))
        model_pairs = [(d, o) for (d, o, _s) in model_out]
        if model_pairs != actual:
            self.errors.append(
                f"python-deframe vs DUT mismatch: {len(model_pairs)} vs {len(actual)}")
        for (_d, _o, s) in model_out:
            if not fm.sync_is_legal(s):
                self.errors.append(f"illegal sync header 0b{s:02b} in DUT stream")
                break

        self.logger.info(
            f"[SB] driven={len(expected)} recovered={len(actual)} "
            f"stream_words={len(stream)} model_words={len(model_stream)}")

    def report_phase(self):
        if self.errors:
            for e in self.errors:
                self.logger.error(f"[SB] {e}")
        else:
            self.logger.info("[SB] datapath cross-check PASS (3-way agreement)")


class Pipe7DatapathEnv(uvm_env):
    def build_phase(self):
        self.agent = RdiAgent("agent", self)
        self.sb = DatapathScoreboard("sb", self)

    def connect_phase(self):
        self.agent.driver.ap.connect(self.sb.exp_fifo.analysis_export)
        self.agent.out_mon.ap.connect(self.sb.act_fifo.analysis_export)
        self.agent.out_mon.stream_ap.connect(self.sb.stream_fifo.analysis_export)
        # expose the monitor so the test can check sync_error / lock after the run
        ConfigDB().set(None, "*", "OUT_MON", self.agent.out_mon)
