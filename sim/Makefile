# TernaryCore simulation Makefile
# Requires: icarus-verilog (brew install icarus-verilog)
# Waveforms: open .vcd files in VSCode with the WaveTrace extension

IVERILOG = iverilog
VVP      = vvp
SIMDIR   = .

.PHONY: all tb_ternary_mac tb_ternary_dot tb_ternary_gemm tb_axi_gemm_wrapper tb_weight_bram tb_kv_cache clean verify

all: tb_ternary_mac tb_ternary_dot tb_ternary_gemm tb_axi_gemm_wrapper tb_weight_bram tb_kv_cache

# ── MAC unit ──────────────────────────────────────────────────────────────────
tb_ternary_mac: ../tb/tb_ternary_mac.v ../rtl/ternary_mac.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_mac $^
	$(VVP) $(SIMDIR)/sim_mac

# ── Dot product ───────────────────────────────────────────────────────────────
tb_ternary_dot: ../tb/tb_ternary_dot.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_dot $^
	$(VVP) $(SIMDIR)/sim_dot

# ── Matrix multiply ───────────────────────────────────────────────────────────
tb_ternary_gemm: tb_ternary_gemm_depth4 tb_ternary_gemm_depth16 tb_ternary_gemm_depth64

tb_ternary_gemm_depth4: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=4 -o $(SIMDIR)/sim_gemm_d4 $^
	$(VVP) $(SIMDIR)/sim_gemm_d4

tb_ternary_gemm_depth16: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=16 -o $(SIMDIR)/sim_gemm_d16 $^
	$(VVP) $(SIMDIR)/sim_gemm_d16

tb_ternary_gemm_depth64: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=64 -o $(SIMDIR)/sim_gemm_d64 $^
	$(VVP) $(SIMDIR)/sim_gemm_d64

# ── AXI4-Lite GEMM wrapper ────────────────────────────────────────────────────
tb_axi_gemm_wrapper: tb_axi_gemm_wrapper_depth4 tb_axi_gemm_wrapper_depth16 tb_axi_gemm_wrapper_depth64

tb_axi_gemm_wrapper_depth4: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=4 -o $(SIMDIR)/sim_axi_gemm_d4 $^
	$(VVP) $(SIMDIR)/sim_axi_gemm_d4

tb_axi_gemm_wrapper_depth16: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=16 -o $(SIMDIR)/sim_axi_gemm_d16 $^
	$(VVP) $(SIMDIR)/sim_axi_gemm_d16

tb_axi_gemm_wrapper_depth64: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=64 -o $(SIMDIR)/sim_axi_gemm_d64 $^
	$(VVP) $(SIMDIR)/sim_axi_gemm_d64

# ── BRAM weight cache ────────────────────────────────────────────────────────
tb_weight_bram: tb_weight_bram_d4 tb_weight_bram_d8

tb_weight_bram_d4: ../tb/tb_weight_bram.v ../rtl/weight_bram.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=4 -o $(SIMDIR)/sim_weight_bram_d4 $^
	$(VVP) $(SIMDIR)/sim_weight_bram_d4

tb_weight_bram_d8: ../tb/tb_weight_bram.v ../rtl/weight_bram.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=8 -o $(SIMDIR)/sim_weight_bram_d8 $^
	$(VVP) $(SIMDIR)/sim_weight_bram_d8

# ── INT4 KV-cache IP ────────────────────────────────────────────────────────
KV_RTL = ../rtl/kv_addr_gen.v ../rtl/int4_unpack.v ../rtl/kv_dequant.v \
	../rtl/qk_dot.v ../rtl/kv_reader.v ../rtl/kv_cache_engine.v

tb_kv_cache: tb_int4_unpack tb_kv_dequant tb_qk_dot tb_kv_cache_engine tb_kv_cache_engine_256 tb_axi_kv_cache

tb_int4_unpack: ../tb/tb_int4_unpack.v ../rtl/int4_unpack.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_int4_unpack $^
	$(VVP) $(SIMDIR)/sim_int4_unpack

tb_kv_dequant: ../tb/tb_kv_dequant.v ../rtl/kv_dequant.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_dequant $^
	$(VVP) $(SIMDIR)/sim_kv_dequant

tb_qk_dot: ../tb/tb_qk_dot.v ../rtl/qk_dot.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_qk_dot $^
	$(VVP) $(SIMDIR)/sim_qk_dot

tb_kv_cache_engine: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_cache_engine $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine

tb_kv_cache_engine_256: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -DAXI_DATA_WIDTH_VAL=256 -o $(SIMDIR)/sim_kv_cache_engine_256 $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine_256

tb_axi_kv_cache: ../tb/tb_axi_kv_cache.v ../rtl/axi_kv_cache.v $(KV_RTL)
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_axi_kv_cache $^
	$(VVP) $(SIMDIR)/sim_axi_kv_cache

# ── Python reference verification ─────────────────────────────────────────────
verify:
	python3 verify/verify_mac.py
	python3 verify/verify_dot.py
	python3 verify/verify_gemm.py
	python3 verify/verify_kv_int4.py

clean:
	rm -f $(SIMDIR)/sim_* $(SIMDIR)/*.vcd
