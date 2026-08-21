# TernaryCore simulation Makefile
# Requires: icarus-verilog (brew install icarus-verilog)
# Waveforms: open .vcd files in VSCode with the WaveTrace extension

IVERILOG = iverilog
VVP      = vvp
SIMDIR   = .

.PHONY: all tb_ternary_mac tb_ternary_dot tb_ternary_gemm tb_axi_gemm_wrapper tb_weight_bram tb_tier2_cols64_projection_only tb_kv_cache tb_kv_v03_page128_offset_scheduler tb_kv_v03_hp64_range_reader tb_kv_v03_page128_record_validator tb_kv_v03_page_prefetch_slot tb_kv_v03_page_pingpong tb_kv_v03_kv_page_prefetch tb_kv_v03_decoded_page_buffer tb_kv_v03_typed_decode_lane_bank_4x1 tb_kv_v03_decoders tb_kv_v03_decoder_cluster_2x2 tb_kv_v03_decoder_cluster_4x1 tb_kv_v03_reciprocal tb_kv_v03_score_store tb_kv_v03_qk_score_quantizer tb_kv_v03_score_row_commit_guard tb_kv_v03_raw_k4_qk_engine tb_kv_v03_canned_page_arithmetic tb_axi_kvq_canned_page_diag tb_kv_v03_softmax tb_kv_v03_v5_weight_mul tb_kv_v03_av tb_kv_v03_av_normalizer tb_kv_v03_softmax_av_pipeline tb_axi_kvq_raw_attention_diag tb_axi_kvq_raw_full_diag tb_axi_v5_av_diag clean verify analyze_kv

all: tb_ternary_mac tb_ternary_dot tb_ternary_gemm tb_axi_gemm_wrapper tb_weight_bram tb_kv_cache

# ── MAC unit ──────────────────────────────────────────────────────────────────
tb_ternary_mac: ../tb/tb_ternary_mac.v ../rtl/ternary_mac.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_mac $^
	$(VVP) $(SIMDIR)/sim_mac

# ── Dot product ───────────────────────────────────────────────────────────────
tb_ternary_dot: ../tb/tb_ternary_dot.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_dot $^
	$(VVP) $(SIMDIR)/sim_dot

# ── Matrix multiply ───────────────────────────────────────────────────────────
tb_ternary_gemm: tb_ternary_gemm_depth4 tb_ternary_gemm_depth16 tb_ternary_gemm_depth64

tb_ternary_gemm_depth4: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=4 -o $(SIMDIR)/sim_gemm_d4 $^
	$(VVP) $(SIMDIR)/sim_gemm_d4

tb_ternary_gemm_depth16: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=16 -o $(SIMDIR)/sim_gemm_d16 $^
	$(VVP) $(SIMDIR)/sim_gemm_d16

tb_ternary_gemm_depth64: ../tb/tb_ternary_gemm.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=64 -o $(SIMDIR)/sim_gemm_d64 $^
	$(VVP) $(SIMDIR)/sim_gemm_d64

# ── AXI4-Lite GEMM wrapper ────────────────────────────────────────────────────
tb_axi_gemm_wrapper: tb_axi_gemm_wrapper_depth4 tb_axi_gemm_wrapper_depth16 tb_axi_gemm_wrapper_depth64

tb_axi_gemm_wrapper_depth4: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=4 -o $(SIMDIR)/sim_axi_gemm_d4 $^
	$(VVP) $(SIMDIR)/sim_axi_gemm_d4

tb_axi_gemm_wrapper_depth16: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -DDEPTH_VAL=16 -o $(SIMDIR)/sim_axi_gemm_d16 $^
	$(VVP) $(SIMDIR)/sim_axi_gemm_d16

tb_axi_gemm_wrapper_depth64: ../tb/tb_axi_gemm_wrapper.v ../rtl/axi_gemm_wrapper.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
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

# ── Tier2 COLS64 projection-only (legacy INT8 attention disabled) ───────────
tb_tier2_cols64_projection_only: ../tb/tb_axi_gemm_stream.v ../rtl/axi_gemm_stream.v ../rtl/weight_bram128.v ../rtl/ternary_gemm.v ../rtl/ternary_dot.v ../rtl/ternary_weight.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DENABLE_INT8_VAL=0 -o $(SIMDIR)/sim_tier2_cols64_projection_only $^
	$(VVP) $(SIMDIR)/sim_tier2_cols64_projection_only

# ── INT4 KV-cache IP ────────────────────────────────────────────────────────
KV_RTL = ../rtl/kv_addr_gen.v ../rtl/int4_unpack.v ../rtl/kv_dequant.v \
	../rtl/qk_dot.v ../rtl/qk_group_dot.v ../rtl/kv_reader.v ../rtl/kv_cache_engine.v

tb_kv_cache: tb_int4_unpack tb_kv_v03_crc32 tb_kv_v03_page_header \
	tb_kv_v03_page128_offset_scheduler \
	tb_kv_v03_hp64_range_reader \
	tb_kv_v03_page128_record_validator \
	tb_kv_v03_page_prefetch_slot \
	tb_kv_v03_page_pingpong \
	tb_kv_v03_kv_page_prefetch \
	tb_kv_v03_decoded_page_buffer \
	tb_kv_v03_typed_decode_lane_bank_4x1 \
	tb_kv_v03_scale12_reader tb_kv_v03_decoders \
	tb_kv_v03_decoder_cluster_2x2 tb_kv_v03_decoder_cluster_4x1 \
	tb_kv_v03_reciprocal \
	tb_kv_v03_score_store tb_kv_v03_qk_score_quantizer \
	tb_kv_v03_score_row_commit_guard tb_kv_v03_raw_k4_qk_engine \
	tb_kv_v03_canned_page_arithmetic tb_axi_kvq_canned_page_diag \
	tb_kv_v03_softmax \
	tb_kv_v03_v5_weight_mul tb_kv_v03_av tb_kv_v03_av_normalizer \
	tb_kv_v03_softmax_av_pipeline tb_axi_kvq_raw_attention_diag \
	tb_axi_kvq_raw_full_diag tb_axi_v5_av_diag \
	tb_kv_dequant tb_qk_dot tb_qk_group_dot \
	tb_kv_cache_engine tb_kv_cache_engine_256 \
	tb_kv_cache_engine_hd128 tb_kv_cache_engine_hd128_256 \
	tb_axi_kv_cache tb_axi_kv_cache_hd128

tb_int4_unpack: ../tb/tb_int4_unpack.v ../rtl/int4_unpack.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_int4_unpack $^
	$(VVP) $(SIMDIR)/sim_int4_unpack

tb_kv_v03_crc32: ../tb/tb_kv_v03_crc32.v ../rtl/kv_v03_crc32.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_crc32 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_crc32

tb_kv_v03_page_header: ../tb/tb_kv_v03_page_header.v ../rtl/kv_v03_page_header.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_page_header $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page_header

tb_kv_v03_page128_offset_scheduler: \
	tb_kv_v03_page128_offset_scheduler_32_12 \
	tb_kv_v03_page128_offset_scheduler_32_16 \
	tb_kv_v03_page128_offset_scheduler_64_12 \
	tb_kv_v03_page128_offset_scheduler_64_16

tb_kv_v03_page128_offset_scheduler_32_12: ../tb/tb_kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_crc32.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=32 -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_32_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_32_12

tb_kv_v03_page128_offset_scheduler_32_16: ../tb/tb_kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_crc32.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=32 -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_32_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_32_16

tb_kv_v03_page128_offset_scheduler_64_12: ../tb/tb_kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_crc32.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=64 -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_64_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_64_12

tb_kv_v03_page128_offset_scheduler_64_16: ../tb/tb_kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_page128_offset_scheduler.v ../rtl/kv_v03_crc32.v
	$(IVERILOG) -g2012 -DADDR_WIDTH_VAL=64 -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_64_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_offset_scheduler_64_16

tb_kv_v03_hp64_range_reader: ../tb/tb_kv_v03_hp64_range_reader.v ../rtl/kv_v03_hp64_range_reader.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -o $(SIMDIR)/sim_kv_v03_hp64_range_reader $^
	$(VVP) $(SIMDIR)/sim_kv_v03_hp64_range_reader

KV_V03_PAGE128_RECORD_VALIDATOR_RTL = ../rtl/kv_v03_page128_record_validator.v \
	../rtl/kv_v03_page_header.v ../rtl/kv_v03_crc32.v \
	../rtl/kv_v03_scale12_reader.v

tb_kv_v03_page128_record_validator: \
	tb_kv_v03_page128_record_validator_12 \
	tb_kv_v03_page128_record_validator_16

tb_kv_v03_page128_record_validator_12: ../tb/tb_kv_v03_page128_record_validator.v $(KV_V03_PAGE128_RECORD_VALIDATOR_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_page128_record_validator_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_record_validator_12

tb_kv_v03_page128_record_validator_16: ../tb/tb_kv_v03_page128_record_validator.v $(KV_V03_PAGE128_RECORD_VALIDATOR_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_page128_record_validator_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page128_record_validator_16

KV_V03_PAGE_PREFETCH_SLOT_RTL = ../rtl/kv_v03_page_prefetch_slot.v \
	../rtl/kv_v03_hp64_range_reader.v \
	$(KV_V03_PAGE128_RECORD_VALIDATOR_RTL)

tb_kv_v03_page_prefetch_slot: \
	tb_kv_v03_page_prefetch_slot_12 \
	tb_kv_v03_page_prefetch_slot_16

tb_kv_v03_page_prefetch_slot_12: ../tb/tb_kv_v03_page_prefetch_slot.v $(KV_V03_PAGE_PREFETCH_SLOT_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_page_prefetch_slot_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page_prefetch_slot_12

tb_kv_v03_page_prefetch_slot_16: ../tb/tb_kv_v03_page_prefetch_slot.v $(KV_V03_PAGE_PREFETCH_SLOT_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_page_prefetch_slot_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page_prefetch_slot_16

KV_V03_PAGE_PINGPONG_RTL = ../rtl/kv_v03_page_pingpong.v \
	$(KV_V03_PAGE_PREFETCH_SLOT_RTL)

tb_kv_v03_page_pingpong: \
	tb_kv_v03_page_pingpong_12 \
	tb_kv_v03_page_pingpong_16

tb_kv_v03_page_pingpong_12: ../tb/tb_kv_v03_page_pingpong.v $(KV_V03_PAGE_PINGPONG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_page_pingpong_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page_pingpong_12

tb_kv_v03_page_pingpong_16: ../tb/tb_kv_v03_page_pingpong.v $(KV_V03_PAGE_PINGPONG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_page_pingpong_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_page_pingpong_16

KV_V03_KV_PAGE_PREFETCH_RTL = ../rtl/kv_v03_kv_page_prefetch.v \
	$(KV_V03_PAGE_PINGPONG_RTL)

tb_kv_v03_kv_page_prefetch: \
	tb_kv_v03_kv_page_prefetch_12 \
	tb_kv_v03_kv_page_prefetch_16

tb_kv_v03_kv_page_prefetch_12: ../tb/tb_kv_v03_kv_page_prefetch.v $(KV_V03_KV_PAGE_PREFETCH_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_kv_page_prefetch_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_kv_page_prefetch_12

tb_kv_v03_kv_page_prefetch_16: ../tb/tb_kv_v03_kv_page_prefetch.v $(KV_V03_KV_PAGE_PREFETCH_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_kv_page_prefetch_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_kv_page_prefetch_16

tb_kv_v03_scale12_reader: ../tb/tb_kv_v03_scale12_reader.v ../rtl/kv_v03_scale12_reader.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_scale12_reader $^
	$(VVP) $(SIMDIR)/sim_kv_v03_scale12_reader

KV_V03_DECODED_PAGE_BUFFER_RTL = ../rtl/kv_v03_decoded_page_buffer.v \
	../rtl/kv_v03_symbol_decoder.v ../rtl/kv_v03_scale12_reader.v

tb_kv_v03_decoded_page_buffer: \
	tb_kv_v03_decoded_page_buffer_12 \
	tb_kv_v03_decoded_page_buffer_16

tb_kv_v03_decoded_page_buffer_12: ../tb/tb_kv_v03_decoded_page_buffer.v $(KV_V03_DECODED_PAGE_BUFFER_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_decoded_page_buffer_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_decoded_page_buffer_12

tb_kv_v03_decoded_page_buffer_16: ../tb/tb_kv_v03_decoded_page_buffer.v $(KV_V03_DECODED_PAGE_BUFFER_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_decoded_page_buffer_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_decoded_page_buffer_16

KV_V03_TYPED_DECODE_LANE_BANK_RTL = \
	../rtl/kv_v03_typed_decode_lane_bank_4x1.v \
	../rtl/kv_v03_symbol_decoder.v

tb_kv_v03_typed_decode_lane_bank_4x1: \
	tb_kv_v03_typed_decode_lane_bank_4x1_12 \
	tb_kv_v03_typed_decode_lane_bank_4x1_16

tb_kv_v03_typed_decode_lane_bank_4x1_12: ../tb/tb_kv_v03_typed_decode_lane_bank_4x1.v $(KV_V03_TYPED_DECODE_LANE_BANK_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_typed_decode_lane_bank_4x1_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_typed_decode_lane_bank_4x1_12

tb_kv_v03_typed_decode_lane_bank_4x1_16: ../tb/tb_kv_v03_typed_decode_lane_bank_4x1.v $(KV_V03_TYPED_DECODE_LANE_BANK_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_typed_decode_lane_bank_4x1_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_typed_decode_lane_bank_4x1_16

tb_kv_v03_decoders: ../tb/tb_kv_v03_decoders.v ../rtl/kv_v03_symbol_decoder.v ../rtl/kv_v03_k4_decoder.v ../rtl/kv_v03_v5_decoder.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_decoders $^
	$(VVP) $(SIMDIR)/sim_kv_v03_decoders +GOLDEN_ROOT=../analysis/kv_validation/v0_3/codec/decoder_goldens

tb_kv_v03_decoder_cluster_2x2: ../tb/tb_kv_v03_decoder_cluster_2x2.v ../rtl/kv_v03_symbol_decoder.v ../rtl/kv_v03_decoder_cluster_2x2.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_decoder_cluster_2x2 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_decoder_cluster_2x2 +GOLDEN_ROOT=../analysis/kv_validation/v0_3/codec/decoder_goldens

tb_kv_v03_decoder_cluster_4x1: ../tb/tb_kv_v03_decoder_cluster_4x1.v ../rtl/kv_v03_symbol_decoder.v ../rtl/kv_v03_decoder_cluster_4x1.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_decoder_cluster_4x1 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_decoder_cluster_4x1 +GOLDEN_ROOT=../analysis/kv_validation/v0_3/codec/decoder_goldens

SOFTMAX_GOLDEN = ../analysis/kv_validation/v0_3/rtl_goldens/softmax

tb_kv_v03_reciprocal: ../tb/tb_kv_v03_reciprocal.v ../rtl/kv_v03_reciprocal.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_reciprocal $^
	$(VVP) $(SIMDIR)/sim_kv_v03_reciprocal +GOLDEN_ROOT=$(SOFTMAX_GOLDEN)

tb_kv_v03_score_store: ../tb/tb_kv_v03_score_store.v ../rtl/kv_v03_score_store.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_score_store $^
	$(VVP) $(SIMDIR)/sim_kv_v03_score_store

tb_kv_v03_qk_score_quantizer: \
	tb_kv_v03_qk_score_quantizer_f8 \
	tb_kv_v03_qk_score_quantizer_f11

tb_kv_v03_qk_score_quantizer_f8: ../tb/tb_kv_v03_qk_score_quantizer.v ../rtl/kv_v03_qk_score_quantizer.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_FRACTION_BITS_VAL=8 -o $(SIMDIR)/sim_kv_v03_qk_score_quantizer_f8 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_qk_score_quantizer_f8

tb_kv_v03_qk_score_quantizer_f11: ../tb/tb_kv_v03_qk_score_quantizer.v ../rtl/kv_v03_qk_score_quantizer.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_FRACTION_BITS_VAL=11 -o $(SIMDIR)/sim_kv_v03_qk_score_quantizer_f11 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_qk_score_quantizer_f11

tb_kv_v03_score_row_commit_guard: ../tb/tb_kv_v03_score_row_commit_guard.v ../rtl/kv_v03_score_row_commit_guard.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -o $(SIMDIR)/sim_kv_v03_score_row_commit_guard $^
	$(VVP) $(SIMDIR)/sim_kv_v03_score_row_commit_guard

KV_V03_RAW_K4_QK_RTL = ../rtl/kv_v03_raw_k4_qk_engine.v \
	../rtl/kv_v03_hp64_range_reader.v ../rtl/qk_group_dot.v \
	../rtl/kv_v03_qk_score_quantizer.v

tb_kv_v03_raw_k4_qk_engine: \
	tb_kv_v03_raw_k4_qk_engine_12 \
	tb_kv_v03_raw_k4_qk_engine_16

tb_kv_v03_raw_k4_qk_engine_12: ../tb/tb_kv_v03_raw_k4_qk_engine.v $(KV_V03_RAW_K4_QK_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=12 -o $(SIMDIR)/sim_kv_v03_raw_k4_qk_engine_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_raw_k4_qk_engine_12

tb_kv_v03_raw_k4_qk_engine_16: ../tb/tb_kv_v03_raw_k4_qk_engine.v $(KV_V03_RAW_K4_QK_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=16 -o $(SIMDIR)/sim_kv_v03_raw_k4_qk_engine_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_raw_k4_qk_engine_16

KV_V03_CANNED_PAGE_ARITHMETIC_RTL = \
	../rtl/kv_v03_canned_page_arithmetic.v ../rtl/qk_group_dot.v \
	../rtl/kv_v03_qk_score_quantizer.v \
	../rtl/kv_v03_score_row_commit_guard.v \
	../rtl/kv_v03_softmax_engine.v ../rtl/kv_v03_score_store.v \
	../rtl/kv_v03_exp_lut.v ../rtl/kv_v03_reciprocal.v \
	../rtl/kv_v03_softmax.v ../rtl/kv_v03_av_accumulator.v \
	../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_normalizer.v

tb_kv_v03_canned_page_arithmetic: \
	tb_kv_v03_canned_page_arithmetic_12 \
	tb_kv_v03_canned_page_arithmetic_16

tb_kv_v03_canned_page_arithmetic_12: ../tb/tb_kv_v03_canned_page_arithmetic.v $(KV_V03_CANNED_PAGE_ARITHMETIC_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_kv_v03_canned_page_arithmetic_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_canned_page_arithmetic_12

tb_kv_v03_canned_page_arithmetic_16: ../tb/tb_kv_v03_canned_page_arithmetic.v $(KV_V03_CANNED_PAGE_ARITHMETIC_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_kv_v03_canned_page_arithmetic_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_canned_page_arithmetic_16

AXI_KVQ_CANNED_PAGE_DIAG_RTL = \
	../rtl/axi_kvq_canned_page_diag.v \
	../rtl/kv_v03_typed_decode_lane_bank_4x1.v \
	../rtl/kv_v03_symbol_decoder.v ../rtl/kv_v03_scale12_reader.v \
	../rtl/kv_v03_page128_record_validator.v \
	../rtl/kv_v03_page_header.v ../rtl/kv_v03_crc32.v \
	$(KV_V03_CANNED_PAGE_ARITHMETIC_RTL)

tb_axi_kvq_canned_page_diag: \
	tb_axi_kvq_canned_page_diag_12 \
	tb_axi_kvq_canned_page_diag_16

tb_axi_kvq_canned_page_diag_12: ../tb/tb_axi_kvq_canned_page_diag.v $(AXI_KVQ_CANNED_PAGE_DIAG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=12 -o $(SIMDIR)/sim_axi_kvq_canned_page_diag_12 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_canned_page_diag_12

tb_axi_kvq_canned_page_diag_16: ../tb/tb_axi_kvq_canned_page_diag.v $(AXI_KVQ_CANNED_PAGE_DIAG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_BITS_VAL=16 -o $(SIMDIR)/sim_axi_kvq_canned_page_diag_16 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_canned_page_diag_16

tb_kv_v03_softmax: ../tb/tb_kv_v03_softmax.v ../rtl/kv_v03_softmax_engine.v ../rtl/kv_v03_score_store.v ../rtl/kv_v03_exp_lut.v ../rtl/kv_v03_reciprocal.v ../rtl/kv_v03_softmax.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_v03_softmax $^
	$(VVP) $(SIMDIR)/sim_kv_v03_softmax +GOLDEN_ROOT=$(SOFTMAX_GOLDEN)

AV_GOLDEN = ../analysis/kv_validation/v0_3/rtl_goldens/av

tb_kv_v03_v5_weight_mul: ../tb/tb_kv_v03_v5_weight_mul.v ../rtl/kv_v03_v5_weight_mul.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -o $(SIMDIR)/sim_kv_v03_v5_weight_mul $^
	$(VVP) $(SIMDIR)/sim_kv_v03_v5_weight_mul

tb_kv_v03_av: tb_kv_v03_av_style0 tb_kv_v03_av_style1 \
	tb_kv_v03_av_style2 tb_kv_v03_av_scale16_style2

tb_kv_v03_av_style0: ../tb/tb_kv_v03_av_accumulator.v ../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_accumulator.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DMULT_STYLE_VAL=0 -o $(SIMDIR)/sim_kv_v03_av_style0 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_av_style0 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_kv_v03_av_style1: ../tb/tb_kv_v03_av_accumulator.v ../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_accumulator.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DMULT_STYLE_VAL=1 -o $(SIMDIR)/sim_kv_v03_av_style1 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_av_style1 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_kv_v03_av_style2: ../tb/tb_kv_v03_av_accumulator.v ../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_accumulator.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DMULT_STYLE_VAL=2 -o $(SIMDIR)/sim_kv_v03_av_style2 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_av_style2 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_kv_v03_av_scale16_style2: ../tb/tb_kv_v03_av_accumulator.v ../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_accumulator.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -DMULT_STYLE_VAL=2 -DSCALE_WIDTH_VAL=16 -o $(SIMDIR)/sim_kv_v03_av_scale16_style2 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_av_scale16_style2 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_kv_v03_av_normalizer: ../tb/tb_kv_v03_av_normalizer.v ../rtl/kv_v03_av_normalizer.v
	$(IVERILOG) -g2012 -Wall -Wimplicit -o $(SIMDIR)/sim_kv_v03_av_normalizer $^
	$(VVP) $(SIMDIR)/sim_kv_v03_av_normalizer

KV_V03_SOFTMAX_AV_PIPELINE_RTL = ../rtl/kv_v03_softmax_av_pipeline.v \
	../rtl/kv_v03_softmax_engine.v ../rtl/kv_v03_softmax.v \
	../rtl/kv_v03_score_store.v ../rtl/kv_v03_exp_lut.v \
	../rtl/kv_v03_reciprocal.v ../rtl/kv_v03_raw_v5_av_engine.v \
	../rtl/kv_v03_raw_v5_axi_reader.v ../rtl/kv_v03_av_accumulator.v \
	../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_normalizer.v

tb_kv_v03_softmax_av_pipeline: \
	tb_kv_v03_softmax_av_pipeline_12 \
	tb_kv_v03_softmax_av_pipeline_16

tb_kv_v03_softmax_av_pipeline_12: ../tb/tb_kv_v03_softmax_av_pipeline.v $(KV_V03_SOFTMAX_AV_PIPELINE_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=12 -o $(SIMDIR)/sim_kv_v03_softmax_av_pipeline_12 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_softmax_av_pipeline_12

tb_kv_v03_softmax_av_pipeline_16: ../tb/tb_kv_v03_softmax_av_pipeline.v $(KV_V03_SOFTMAX_AV_PIPELINE_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=16 -o $(SIMDIR)/sim_kv_v03_softmax_av_pipeline_16 $^
	$(VVP) $(SIMDIR)/sim_kv_v03_softmax_av_pipeline_16

tb_axi_kvq_raw_attention_diag: \
	tb_axi_kvq_raw_attention_diag_12 \
	tb_axi_kvq_raw_attention_diag_16

tb_axi_kvq_raw_attention_diag_12: ../tb/tb_axi_kvq_raw_attention_diag.v ../rtl/axi_kvq_raw_attention_diag.v $(KV_V03_SOFTMAX_AV_PIPELINE_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=12 -DAXI_DATA_WIDTH_VAL=64 -o $(SIMDIR)/sim_axi_kvq_raw_attention_diag_12 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_attention_diag_12

tb_axi_kvq_raw_attention_diag_16: ../tb/tb_axi_kvq_raw_attention_diag.v ../rtl/axi_kvq_raw_attention_diag.v $(KV_V03_SOFTMAX_AV_PIPELINE_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=16 -DAXI_DATA_WIDTH_VAL=64 -o $(SIMDIR)/sim_axi_kvq_raw_attention_diag_16 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_attention_diag_16

KV_V03_RAW_FULL_RTL = ../rtl/axi_kvq_raw_full_diag.v \
	$(KV_V03_RAW_K4_QK_RTL) ../rtl/kv_v03_score_row_commit_guard.v \
	$(KV_V03_SOFTMAX_AV_PIPELINE_RTL)

tb_axi_kvq_raw_full_diag: \
	tb_axi_kvq_raw_full_diag_12 \
	tb_axi_kvq_raw_full_diag_12_128 \
	tb_axi_kvq_raw_full_diag_16 \
	tb_axi_kvq_raw_full_diag_16_128

tb_axi_kvq_raw_full_diag_12: ../tb/tb_axi_kvq_raw_full_diag.v $(KV_V03_RAW_FULL_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=12 -DAXI_DATA_WIDTH_VAL=64 -o $(SIMDIR)/sim_axi_kvq_raw_full_diag_12 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_full_diag_12

tb_axi_kvq_raw_full_diag_12_128: ../tb/tb_axi_kvq_raw_full_diag.v $(KV_V03_RAW_FULL_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=12 -DAXI_DATA_WIDTH_VAL=128 -o $(SIMDIR)/sim_axi_kvq_raw_full_diag_12_128 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_full_diag_12_128

tb_axi_kvq_raw_full_diag_16: ../tb/tb_axi_kvq_raw_full_diag.v $(KV_V03_RAW_FULL_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=16 -DAXI_DATA_WIDTH_VAL=64 -o $(SIMDIR)/sim_axi_kvq_raw_full_diag_16 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_full_diag_16

tb_axi_kvq_raw_full_diag_16_128: ../tb/tb_axi_kvq_raw_full_diag.v $(KV_V03_RAW_FULL_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DSCALE_WIDTH_VAL=16 -DAXI_DATA_WIDTH_VAL=128 -o $(SIMDIR)/sim_axi_kvq_raw_full_diag_16_128 $^
	$(VVP) $(SIMDIR)/sim_axi_kvq_raw_full_diag_16_128

AXI_V5_AV_DIAG_RTL = ../rtl/axi_v5_av_diag.v \
	../rtl/kv_v03_raw_v5_av_engine.v ../rtl/kv_v03_raw_v5_axi_reader.v \
	../rtl/kv_v03_v5_weight_mul.v ../rtl/kv_v03_av_accumulator.v

tb_axi_v5_av_diag: tb_axi_v5_av_diag_64 tb_axi_v5_av_diag_128

tb_axi_v5_av_diag_64: ../tb/tb_axi_v5_av_diag.v $(AXI_V5_AV_DIAG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DAXI_DATA_WIDTH_VAL=64 -o $(SIMDIR)/sim_axi_v5_av_diag_64 $^
	$(VVP) $(SIMDIR)/sim_axi_v5_av_diag_64 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_axi_v5_av_diag_128: ../tb/tb_axi_v5_av_diag.v $(AXI_V5_AV_DIAG_RTL)
	$(IVERILOG) -g2012 -Wall -Wimplicit -DAXI_DATA_WIDTH_VAL=128 -o $(SIMDIR)/sim_axi_v5_av_diag_128 $^
	$(VVP) $(SIMDIR)/sim_axi_v5_av_diag_128 +GOLDEN_ROOT=$(AV_GOLDEN)

tb_kv_dequant: ../tb/tb_kv_dequant.v ../rtl/kv_dequant.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_dequant $^
	$(VVP) $(SIMDIR)/sim_kv_dequant

tb_qk_dot: ../tb/tb_qk_dot.v ../rtl/qk_dot.v
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_qk_dot $^
	$(VVP) $(SIMDIR)/sim_qk_dot

QK_GOLDEN = ../analysis/kv_validation/real_model/qk_profile_golden_v0_2

tb_qk_group_dot: tb_qk_group_dot_k4_style0 tb_qk_group_dot_k4_style2 \
	tb_qk_group_dot_k5_style0 tb_qk_group_dot_k5_style2

tb_qk_group_dot_k4_style0: ../tb/tb_qk_group_dot.v ../rtl/qk_group_dot.v
	$(IVERILOG) -g2012 -DK_WIDTH_VAL=4 -DMULT_STYLE_VAL=0 -o $(SIMDIR)/sim_qk_group_dot_k4_style0 $^
	$(VVP) $(SIMDIR)/sim_qk_group_dot_k4_style0 +GOLDEN_ROOT=$(QK_GOLDEN)/regular4

tb_qk_group_dot_k4_style2: ../tb/tb_qk_group_dot.v ../rtl/qk_group_dot.v
	$(IVERILOG) -g2012 -DK_WIDTH_VAL=4 -DMULT_STYLE_VAL=2 -o $(SIMDIR)/sim_qk_group_dot_k4_style2 $^
	$(VVP) $(SIMDIR)/sim_qk_group_dot_k4_style2 +GOLDEN_ROOT=$(QK_GOLDEN)/regular4

tb_qk_group_dot_k5_style0: ../tb/tb_qk_group_dot.v ../rtl/qk_group_dot.v
	$(IVERILOG) -g2012 -DK_WIDTH_VAL=5 -DMULT_STYLE_VAL=0 -o $(SIMDIR)/sim_qk_group_dot_k5_style0 $^
	$(VVP) $(SIMDIR)/sim_qk_group_dot_k5_style0 +GOLDEN_ROOT=$(QK_GOLDEN)/accurate5

tb_qk_group_dot_k5_style2: ../tb/tb_qk_group_dot.v ../rtl/qk_group_dot.v
	$(IVERILOG) -g2012 -DK_WIDTH_VAL=5 -DMULT_STYLE_VAL=2 -o $(SIMDIR)/sim_qk_group_dot_k5_style2 $^
	$(VVP) $(SIMDIR)/sim_qk_group_dot_k5_style2 +GOLDEN_ROOT=$(QK_GOLDEN)/accurate5

tb_kv_cache_engine: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_kv_cache_engine $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine

tb_kv_cache_engine_256: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -DAXI_DATA_WIDTH_VAL=256 -o $(SIMDIR)/sim_kv_cache_engine_256 $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine_256

tb_kv_cache_engine_hd128: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -DHEAD_DIM_VAL=128 -o $(SIMDIR)/sim_kv_cache_engine_hd128 $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine_hd128

tb_kv_cache_engine_hd128_256: ../tb/tb_kv_cache_engine.v $(KV_RTL)
	$(IVERILOG) -g2012 -DHEAD_DIM_VAL=128 -DAXI_DATA_WIDTH_VAL=256 -o $(SIMDIR)/sim_kv_cache_engine_hd128_256 $^
	$(VVP) $(SIMDIR)/sim_kv_cache_engine_hd128_256

tb_axi_kv_cache: ../tb/tb_axi_kv_cache.v ../rtl/axi_kv_cache.v $(KV_RTL)
	$(IVERILOG) -g2012 -o $(SIMDIR)/sim_axi_kv_cache $^
	$(VVP) $(SIMDIR)/sim_axi_kv_cache

tb_axi_kv_cache_hd128: ../tb/tb_axi_kv_cache.v ../rtl/axi_kv_cache.v $(KV_RTL)
	$(IVERILOG) -g2012 -DHEAD_DIM_VAL=128 -o $(SIMDIR)/sim_axi_kv_cache_hd128 $^
	$(VVP) $(SIMDIR)/sim_axi_kv_cache_hd128

# ── Python reference verification ─────────────────────────────────────────────
verify:
	python3 verify/verify_mac.py
	python3 verify/verify_dot.py
	python3 verify/verify_gemm.py
	python3 verify/verify_kv_int4.py
	python3 verify/verify_kv_quant.py
	python3 verify/verify_kv_analysis_artifacts.py

# Rebuild the versioned synthetic/numerical, RTL-cycle, and analytical reports.
# This is intentionally not part of the fast verification target.
analyze_kv:
	python3 verify/analyze_kv_quant.py
	python3 verify/analyze_kv_cycles.py
	python3 verify/analyze_kv_system.py

clean:
	rm -f $(SIMDIR)/sim_* $(SIMDIR)/*.vcd
