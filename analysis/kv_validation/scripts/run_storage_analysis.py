#!/usr/bin/env python3
"""Generate THEORETICAL GQA cache and FPGA-layout accounting tables."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any


CONTEXT_LENGTHS = (128, 512, 1024, 2048, 4096)


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields: list[str] = []
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    output = args.output / "hardware_estimates"
    output.mkdir(parents=True, exist_ok=True)
    model = json.loads((args.output / "model_config.json").read_text(
        encoding="utf-8"))["derived"]
    head_dim = int(model["head_dim"])
    kv_heads = int(model["num_key_value_heads"])
    q_heads = int(model["num_attention_heads"])
    layers = int(model["num_hidden_layers"])

    formats = (("FP16", 16, 0), ("INT8", 8, 2), ("INT5", 5, 2),
               ("INT4", 4, 2), ("INT3", 3, 2))
    cache_rows: list[dict[str, Any]] = []
    fp16_pair_per_head = 2.0 * head_dim * 2.0
    for context in CONTEXT_LENGTHS:
        for name, bits, scale_bytes_each in formats:
            payload_each = head_dim * bits / 8.0
            pair_per_head = 2.0 * (payload_each + scale_bytes_each)
            per_token_layer = pair_per_head * kv_heads
            cache_rows.append({
                "evidence": "THEORETICAL",
                "format": name,
                "context_len": context,
                "head_dim": head_dim,
                "q_heads": q_heads,
                "kv_heads": kv_heads,
                "gqa_query_heads_per_kv_head": q_heads // kv_heads,
                "layers": layers,
                "payload_bytes_per_k_or_v_vector": payload_each,
                "scale_metadata_bytes_per_k_or_v_vector": scale_bytes_each,
                "kv_pair_bytes_per_token_per_kv_head": pair_per_head,
                "bytes_per_token_per_layer": per_token_layer,
                "bytes_per_context_all_layers": per_token_layer * context * layers,
                "effective_bits_per_value_including_metadata":
                    pair_per_head * 8.0 / (2.0 * head_dim),
                "compression_vs_fp16_equal_geometry":
                    fp16_pair_per_head / pair_per_head,
                "accounting_note": "GQA stores KV heads, not Q heads",
            })

    layout_rows: list[dict[str, Any]] = []
    for axi_bits in (128, 256):
        beat_bytes = axi_bits // 8
        for name, bits, scale_bytes_each in formats[1:]:
            payload = head_dim * bits / 8.0
            data_beats = math.ceil(payload / beat_bytes)
            transferred = data_beats * beat_bytes
            for context in CONTEXT_LENGTHS:
                scale_bytes_context = context * scale_bytes_each
                scale_beats_context = math.ceil(scale_bytes_context / beat_bytes)
                combined_useful = context * (payload + scale_bytes_each)
                combined_transferred = (context * transferred +
                                        scale_beats_context * beat_bytes)
                layout_rows.append({
                    "evidence": "THEORETICAL",
                    "format": name,
                    "context_len": context,
                    "head_dim": head_dim,
                    "axi_width_bits": axi_bits,
                    "axi_beat_bytes": beat_bytes,
                    "packed_payload_bytes_per_vector": payload,
                    "data_beats_per_vector_if_independent": data_beats,
                    "data_transfer_bytes_per_vector_if_independent": transferred,
                    "data_alignment_padding_bytes_per_vector": transferred - payload,
                    "scale_metadata_bytes_per_vector": scale_bytes_each,
                    "scales_per_scale_plane_beat": beat_bytes // scale_bytes_each,
                    "scale_plane_beats_per_context": scale_beats_context,
                    "separate_plane_useful_bytes_per_context_per_k_or_v_head":
                        combined_useful,
                    "separate_plane_transferred_bytes_per_context_per_k_or_v_head":
                        combined_transferred,
                    "separate_plane_transfer_efficiency":
                        combined_useful / combined_transferred,
                    "throughput_claim": False,
                })

    layout_compare: list[dict[str, Any]] = []
    int4_payload = head_dim * 4 // 8
    record_bytes = int4_payload + 2
    for axi_bits in (128, 256):
        beat_bytes = axi_bits // 8
        for context in CONTEXT_LENGTHS:
            useful = context * record_bytes
            separate = (math.ceil(context * int4_payload / beat_bytes) +
                        math.ceil(context * 2 / beat_bytes)) * beat_bytes
            interleaved_long = math.ceil(useful / beat_bytes) * beat_bytes
            interleaved_tokenwise = context * math.ceil(
                record_bytes / beat_bytes) * beat_bytes
            layout_compare.extend(({
                "evidence": "THEORETICAL",
                "layout": "separate_data_and_scale_planes",
                "context_len": context,
                "head_dim": head_dim,
                "axi_width_bits": axi_bits,
                "int4_payload_bytes": int4_payload,
                "scale_bytes": 2,
                "record_bytes": record_bytes,
                "long_burst_transferred_bytes": separate,
                "tokenwise_transferred_bytes": (
                    context * math.ceil(int4_payload / beat_bytes) * beat_bytes +
                    math.ceil(context * 2 / beat_bytes) * beat_bytes),
                "data_address_expression": f"K_DATA_BASE + token*{int4_payload}",
                "power_of_two_data_stride": bool(
                    int4_payload & (int4_payload - 1) == 0),
                "independent_scale_prefetch": True,
            }, {
                "evidence": "THEORETICAL",
                "layout": f"interleaved_{record_bytes}_byte_record",
                "context_len": context,
                "head_dim": head_dim,
                "axi_width_bits": axi_bits,
                "int4_payload_bytes": int4_payload,
                "scale_bytes": 2,
                "record_bytes": record_bytes,
                "long_burst_transferred_bytes": interleaved_long,
                "tokenwise_transferred_bytes": interleaved_tokenwise,
                "data_address_expression": f"BASE + token*{record_bytes}",
                "power_of_two_data_stride": False,
                "independent_scale_prefetch": False,
            }))

    granularity_rows: list[dict[str, Any]] = []
    for comparison_dim in (64, head_dim):
        for context in CONTEXT_LENGTHS:
            for label, group_size in (("one_scale_per_run", None),
                                      ("one_scale_per_token", comparison_dim),
                                      ("group32", 32), ("group16", 16),
                                      ("group8", 8)):
                if comparison_dim % (comparison_dim if group_size is None
                                     else group_size):
                    continue
                scales = ((1.0 / context) if group_size is None else
                          comparison_dim / group_size)
                payload = comparison_dim * 4.0 / 8.0
                metadata = scales * 2.0
                total = payload + metadata
                granularity_rows.append({
                    "evidence": "THEORETICAL",
                    "head_dim": comparison_dim,
                    "context_len": context,
                    "scale_granularity": label,
                    "scale_group_size": (context * comparison_dim
                                         if group_size is None else group_size),
                    "int4_payload_bytes_per_k_or_v_vector": payload,
                    "q8_8_metadata_bytes_per_k_or_v_vector": metadata,
                    "total_bytes_per_k_or_v_vector": total,
                    "effective_bits_per_value": total * 8.0 / comparison_dim,
                    "compression_vs_equal_dim_row_major_fp16":
                        2.0 * comparison_dim / total,
                    "compression_vs_equal_dim_row_major_int8":
                        comparison_dim / total,
                    "compression_vs_equal_dim_bitsliced_int8":
                        2.0 * comparison_dim / total,
                    "compression_vs_actual_existing_128d_256byte_layout":
                        256.0 / total,
                    "actual_existing_comparison_is_equal_dimension":
                        comparison_dim == 128,
                })

    write_csv(output / "gqa_cache_storage.csv", cache_rows)
    write_csv(output / "axi_vector_layout.csv", layout_rows)
    write_csv(output / "int4_layout_comparison.csv", layout_compare)
    write_csv(output / "int4_scale_granularity_storage.csv", granularity_rows)
    summary = {
        "evidence": "THEORETICAL",
        "warning": "Storage/layout arithmetic only; no FPGA throughput claim.",
        "authoritative_geometry": {
            "head_dim": head_dim, "q_heads": q_heads, "kv_heads": kv_heads,
            "layers": layers,
        },
        "separate_plane_recommendation": {
            "preferred": True,
            "int4_data_stride_bytes": int4_payload,
            "address_expression": f"K_DATA_BASE + token*{int4_payload}",
            "scale_stride_bytes": 2,
            "reason": ("power-of-two payload stride, independent scale bursts, "
                       "and no long-burst transfer penalty of consequence"),
        },
        "tables": {
            "gqa_cache_storage": "gqa_cache_storage.csv",
            "axi_vector_layout": "axi_vector_layout.csv",
            "int4_layout_comparison": "int4_layout_comparison.csv",
            "int4_scale_granularity_storage":
                "int4_scale_granularity_storage.csv",
        },
    }
    (output / "storage_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary["authoritative_geometry"], sort_keys=True))


if __name__ == "__main__":
    main()
