# pipe7_cdc_elastic_buf.sdc -- clock-domain-crossing constraints for the RDI<->PCLK elastic
# buffer (closure-plan item 32). Apply per instance (tx_cdc: wr=rdi_clk/rd=pclk; rx_cdc:
# wr=pclk/rd=rdi_clk). These document the CDC timing intent the multiclock formal proof
# (verification/formal/cdc_mc.sby) assumes: independent clocks, Gray-coded pointers crossed
# through 2-flop synchronizers. Names are relative to a pipe7_cdc_elastic_buf instance.
#
# --- Clocks (declare the two domains at the top level; shown here as placeholders) ---
# create_clock -name rdi_clk -period <T_rdi> [get_ports rdi_clk]
# create_clock -name pclk    -period <T_pclk> [get_ports pclk]
# set_clock_groups -asynchronous -group {rdi_clk} -group {pclk}
#
# --- Gray-pointer crossings: bound skew to one destination period so at most one Gray bit is
#     in flight (the Gray code guarantees a single-bit change), then let the 2-flop synchronizer
#     resolve metastability. Use -datapath_only so only the crossing net is constrained. ---
set_max_delay -datapath_only -from [get_cells {wr_ptr_gray_reg[*]}]         -to [get_cells {wr_ptr_gray_sync_r1_reg[*]}] [get_property -object_type clock period pclk]
set_max_delay -datapath_only -from [get_cells {rd_ptr_gray_reg[*]}]         -to [get_cells {rd_ptr_gray_sync_r1_reg[*]}] [get_property -object_type clock period rdi_clk]
#
# --- Synchronizer flops: mark as such so the tools do not report/optimize them, and keep the
#     two stages placed together (ASYNC_REG-style) to minimize MTBF-limiting routing. ---
# set_false_path -hold -from [get_cells {wr_ptr_gray_reg[*]}] -to [get_cells {wr_ptr_gray_sync_r1_reg[*]}]
# set_false_path -hold -from [get_cells {rd_ptr_gray_reg[*]}] -to [get_cells {rd_ptr_gray_sync_r1_reg[*]}]
#
# --- Reset: rst_n is async and fans out into BOTH clock domains. Its ASSERTION is async-safe, but
#     its DEASSERTION must be recovery/removal-clean per domain. A real deployment feeds rst_n
#     through a per-domain reset synchronizer (2 FFs clocked by that domain, async-asserted,
#     sync-deasserted). If that synchronizer is external to this block, cut the raw reset crossing:
# set_false_path -from [get_ports rst_n]
#     and constrain each domain's synchronized reset normally. (See docs/architecture.md.)
