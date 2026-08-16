#!/usr/bin/env python3
"""Run one crash-safe real-model case for KV-cache v0.3 Gate A."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import time
from dataclasses import asdict
from pathlib import Path

import numpy as np
import psutil
import torch
from safetensors import safe_open

from bitnet_streaming_reference import BitNetGeometry, KVQuantProfile, StreamingBitNet
from packed5_page_codec import (
    SCALE_FORMAT_UQ4_8,
    build_page_stream,
    decode_page_stream,
    pack_scale_codes,
    stream_statistics,
)


CAPTURE_LAYERS = {0, 7, 15, 22, 29}
EXECUTION_PROFILES = {
    "BASE_FP": None,
    "PACKED5_RAW_UQ5_11": KVQuantProfile(
        name="PACKED5_RAW_UQ5_11",
        k_bits=4, k_group_size=128,
        v_bits=5, v_group_size=128,
        kv_scale_fraction=11, kv_scale_width=16),
    "PACKED5_PAGE128_UQ4_8": KVQuantProfile(
        name="PACKED5_PAGE128_UQ4_8",
        k_bits=4, k_group_size=128,
        v_bits=5, v_group_size=128,
        kv_scale_fraction=8, kv_scale_width=12),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def relative_rmse(actual: torch.Tensor, reference: torch.Tensor) -> float:
    a = actual.float().double()
    b = reference.float().double()
    return float(torch.sqrt(torch.mean((a - b).square()) /
                            torch.mean(b.square()).clamp_min(1.0e-30)))


def cosine(actual: torch.Tensor, reference: torch.Tensor) -> float:
    a = actual.float().double().reshape(-1)
    b = reference.float().double().reshape(-1)
    return float(torch.dot(a, b) /
                 (torch.linalg.vector_norm(a) *
                  torch.linalg.vector_norm(b)).clamp_min(1.0e-30))


def chunked_vocab_logits(handle, hidden: torch.Tensor,
                         chunk: int = 2048) -> np.ndarray:
    embedding = handle.get_slice("model.embed_tokens.weight")
    vocab_size = embedding.get_shape()[0]
    output = np.empty(vocab_size, dtype=np.float32)
    vector = hidden[-1].float()
    for start in range(0, vocab_size, chunk):
        stop = min(start + chunk, vocab_size)
        weight = embedding[start:stop].float()
        output[start:stop] = torch.mv(weight, vector).numpy()
        del weight
    return output


def distribution_metrics(actual: np.ndarray,
                         reference: np.ndarray) -> dict[str, float | bool]:
    ref_shift = reference.astype(np.float64) - float(np.max(reference))
    act_shift = actual.astype(np.float64) - float(np.max(actual))
    p = np.exp(ref_shift); p /= np.sum(p)
    q = np.exp(act_shift); q /= np.sum(q)
    midpoint = 0.5 * (p + q)
    tiny = np.finfo(np.float64).tiny
    kl = float(np.sum(
        p * (np.log(np.maximum(p, tiny)) - np.log(np.maximum(q, tiny)))))
    js = float(0.5 * np.sum(
        p * (np.log(np.maximum(p, tiny)) - np.log(midpoint))) +
        0.5 * np.sum(
            q * (np.log(np.maximum(q, tiny)) - np.log(midpoint))))
    ref_top5 = np.argpartition(reference, -5)[-5:]
    act_top5 = np.argpartition(actual, -5)[-5:]
    return {
        "kl_reference_to_candidate": kl,
        "js_divergence": js,
        "top1_preserved": bool(
            int(np.argmax(reference)) == int(np.argmax(actual))),
        "top5_exact_set_preserved": bool(
            set(ref_top5.tolist()) == set(act_top5.tolist())),
        "top5_overlap_fraction": (
            len(set(ref_top5.tolist()) & set(act_top5.tolist())) / 5.0),
    }


def percentiles(values: np.ndarray, fraction: int) -> dict[str, float]:
    scales = values.astype(np.float64) / (1 << fraction)
    quantiles = np.percentile(scales, [1, 5, 50, 95, 99])
    return {
        "min": float(scales.min()),
        "p1": float(quantiles[0]),
        "p5": float(quantiles[1]),
        "median": float(quantiles[2]),
        "p95": float(quantiles[3]),
        "p99": float(quantiles[4]),
        "max": float(scales.max()),
    }


class CacheAudit:
    """Observe scale codes and perform both page64/page128 round trips."""

    def __init__(self, *, enable_codec: bool):
        self.enable_codec = enable_codec
        self.scale_codes: dict[str, list[np.ndarray]] = {"K": [], "V": []}
        self.raw_hash = {64: hashlib.sha256(), 128: hashlib.sha256()}
        self.decoded_hash = {64: hashlib.sha256(), 128: hashlib.sha256()}
        self.page_stats = {
            page_tokens: {
                stream: {
                    "tasks": 0,
                    "tokens": 0,
                    "pages": 0,
                    "raw_pages": 0,
                    "record_bytes": [],
                    "full_bytes": 0,
                    "payload_bytes": 0,
                    "header_bytes": 0,
                    "alignment_padding_bytes": 0,
                    "offset_table_bytes": 0,
                    "offset_table_crc_bytes": 0,
                    "stream_descriptor_bytes": 0,
                    "scale_plane_bytes": 0,
                }
                for stream in ("K", "V")
            }
            for page_tokens in (64, 128)
        }

    def __call__(self, label: str, bits: int, scale_fraction: int,
                 codes: torch.Tensor, scale_codes: torch.Tensor,
                 ) -> tuple[torch.Tensor, torch.Tensor]:
        stream = label.rsplit(".", 1)[-1]
        if stream not in ("K", "V"):
            return codes, scale_codes
        codes_np = codes.detach().cpu().numpy().astype(np.int8).reshape(
            codes.shape[0], codes.shape[1], 128)
        scales_np = scale_codes.detach().cpu().numpy().astype(np.uint16).reshape(
            scale_codes.shape[0], scale_codes.shape[1])
        self.scale_codes[stream].append(scales_np.reshape(-1).copy())
        if not self.enable_codec:
            return codes, scale_codes
        if scale_fraction != 8:
            raise AssertionError("page codec Gate A path requires UQ4.8")

        decoded_for_model_codes = np.empty_like(codes_np)
        decoded_for_model_scales = np.empty_like(scales_np)
        for head in range(codes_np.shape[0]):
            head_codes = np.ascontiguousarray(codes_np[head])
            head_scales = np.ascontiguousarray(scales_np[head])
            for page_tokens in (64, 128):
                scale_plane = pack_scale_codes(
                    head_scales, SCALE_FORMAT_UQ4_8)
                page_stream = build_page_stream(
                    head_codes, head_scales, page_tokens=page_tokens,
                    is_v=stream == "V", scale_format_id=SCALE_FORMAT_UQ4_8)
                decoded_codes, decoded_scales = decode_page_stream(
                    page_stream, scale_plane, page_tokens=page_tokens,
                    is_v=stream == "V", scale_format_id=SCALE_FORMAT_UQ4_8,
                    total_tokens=len(head_scales))
                np.testing.assert_array_equal(decoded_codes, head_codes)
                np.testing.assert_array_equal(decoded_scales, head_scales)
                self.raw_hash[page_tokens].update(head_codes.tobytes())
                self.raw_hash[page_tokens].update(head_scales.astype("<u2").tobytes())
                self.decoded_hash[page_tokens].update(decoded_codes.tobytes())
                self.decoded_hash[page_tokens].update(
                    decoded_scales.astype("<u2").tobytes())
                task = self.page_stats[page_tokens][stream]
                stats = stream_statistics(
                    page_stream, len(head_scales), bits, len(scale_plane))
                task["tasks"] += 1
                task["tokens"] += len(head_scales)
                task["pages"] += len(page_stream.pages)
                task["raw_pages"] += sum(
                    page.header.raw for page in page_stream.pages)
                task["record_bytes"].extend(
                    len(page.record) for page in page_stream.pages)
                for field in (
                        "full_bytes", "payload_bytes", "page_header_bytes",
                        "alignment_padding_bytes", "offset_table_bytes",
                        "offset_table_crc_bytes", "stream_descriptor_bytes",
                        "scale_plane_bytes"):
                    destination = (
                        "header_bytes" if field == "page_header_bytes" else field)
                    task[destination] += int(stats[field])
                if page_tokens == 128:
                    decoded_for_model_codes[head] = decoded_codes
                    decoded_for_model_scales[head] = decoded_scales

        return (
            torch.from_numpy(decoded_for_model_codes).to(
                device=codes.device, dtype=codes.dtype).reshape(codes.shape),
            torch.from_numpy(decoded_for_model_scales).to(
                device=scale_codes.device, dtype=scale_codes.dtype).reshape(
                    scale_codes.shape),
        )

    def finalize(self, scale_fraction: int) -> dict:
        scale_result = {}
        for stream in ("K", "V"):
            values = np.concatenate(self.scale_codes[stream])
            scale_result[stream] = {
                "count": int(values.size),
                **percentiles(values, scale_fraction),
            }
        result = {
            "stored_scale_distribution": scale_result,
            "page_roundtrip": {},
        }
        if not self.enable_codec:
            return result
        for page_tokens in (64, 128):
            raw_digest = self.raw_hash[page_tokens].hexdigest()
            decoded_digest = self.decoded_hash[page_tokens].hexdigest()
            if raw_digest != decoded_digest:
                raise AssertionError("raw and decoded code/scale hashes differ")
            page_result = {
                "bit_identical": True,
                "raw_codes_scales_sha256": raw_digest,
                "decoded_codes_scales_sha256": decoded_digest,
                "streams": {},
            }
            for stream in ("K", "V"):
                source = self.page_stats[page_tokens][stream]
                sizes = np.asarray(source.pop("record_bytes"), dtype=np.int64)
                page_result["streams"][stream] = {
                    **source,
                    "raw_fallback_fraction": (
                        source["raw_pages"] / source["pages"]),
                    "average_record_bytes": float(np.mean(sizes)),
                    "p95_record_bytes": float(np.percentile(sizes, 95)),
                    "worst_record_bytes": int(np.max(sizes)),
                    "maximum_bounded_record_bytes": (
                        12 + page_tokens * 128 * (5 if stream == "V" else 4) // 8),
                    "full_bytes_per_token": (
                        source["full_bytes"] / source["tokens"]),
                }
            result["page_roundtrip"][str(page_tokens)] = page_result
        return result


def locate_base(repo: Path, output_root: Path, prompt_id: str,
                context_length: int) -> Path:
    local = output_root / f"context_{context_length:04d}" / prompt_id / "BASE_FP"
    if (local / "run.json").is_file():
        return local
    if context_length == 128 and prompt_id in ("engineering", "observatory"):
        legacy = (repo / "analysis" / "kv_validation" / "real_model" /
                  "end_to_end_injection" / prompt_id / "BASE_FP")
        if (legacy / "run.json").is_file():
            return legacy
    raise FileNotFoundError(
        f"BASE_FP must complete before candidate profile: {local}")


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint", type=Path,
        default=repo.parent / "bitnet-b1.58-2B-4T")
    parser.add_argument(
        "--prompt-record", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "prompts_and_token_ids.json")
    parser.add_argument("--prompt-id", required=True)
    parser.add_argument("--context-length", type=int, choices=(128, 512), required=True)
    parser.add_argument("--profile", choices=tuple(EXECUTION_PROFILES), required=True)
    parser.add_argument(
        "--output-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "gate_a")
    parser.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()

    prompt_data = json.loads(args.prompt_record.read_text(encoding="utf-8"))
    prompt = next(
        row for row in prompt_data["prompts"] if row["prompt_id"] == args.prompt_id)
    context = prompt["contexts"].get(str(args.context_length))
    if context is None:
        raise ValueError(
            f"prompt {args.prompt_id} has no context {args.context_length} record")
    token_ids = context["token_ids"]
    destination = (args.output_root / f"context_{args.context_length:04d}" /
                   args.prompt_id / args.profile)
    destination.mkdir(parents=True, exist_ok=False)
    capture_dir = destination / "captures"
    if args.profile == "BASE_FP":
        capture_dir.mkdir()
    fixedpoint_input_dir = destination / "fixedpoint_inputs"
    if args.profile == "PACKED5_PAGE128_UQ4_8":
        fixedpoint_input_dir.mkdir()

    torch.manual_seed(20260816)
    torch.set_grad_enabled(False)
    torch.set_num_threads(args.threads)
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass
    process = psutil.Process()
    start_time = time.perf_counter()
    prior_time = start_time
    peak_rss = process.memory_info().rss
    timings = []
    scale_audit = []
    layer_metrics = []
    profile = EXECUTION_PROFILES[args.profile]
    cache_audit = CacheAudit(
        enable_codec=args.profile == "PACKED5_PAGE128_UQ4_8")
    base = None if args.profile == "BASE_FP" else locate_base(
        repo, args.output_root, args.prompt_id, args.context_length)

    def capture(layer: int, tensors: dict[str, torch.Tensor]) -> None:
        if args.profile == "BASE_FP":
            torch.save({
                "attention_weighted_v": tensors["attention_weighted_v"],
                "attention_block_output": tensors["attention_block_output"],
            }, capture_dir / f"layer_{layer:02d}.pt")
            return
        if args.profile == "PACKED5_PAGE128_UQ4_8":
            np.savez_compressed(
                fixedpoint_input_dir / f"layer_{layer:02d}_last_query_scores.npz",
                scores=tensors["attention_logits"][:, -1, :].float().numpy(),
                context_length=np.asarray([args.context_length], dtype=np.uint16),
                layer=np.asarray([layer], dtype=np.uint8),
                q_heads=np.asarray([20], dtype=np.uint8),
            )
        reference = torch.load(
            base / "captures" / f"layer_{layer:02d}.pt",
            map_location="cpu", weights_only=True)
        layer_metrics.append({
            "layer": layer,
            "attention_output_relative_rmse": relative_rmse(
                tensors["attention_weighted_v"],
                reference["attention_weighted_v"]),
            "attention_output_cosine": cosine(
                tensors["attention_weighted_v"],
                reference["attention_weighted_v"]),
            "block_output_relative_rmse": relative_rmse(
                tensors["attention_block_output"],
                reference["attention_block_output"]),
            "block_output_cosine": cosine(
                tensors["attention_block_output"],
                reference["attention_block_output"]),
        })

    def progress(layer: int) -> None:
        nonlocal prior_time, peak_rss
        now = time.perf_counter()
        rss = process.memory_info().rss
        peak_rss = max(peak_rss, rss)
        row = {
            "layer": layer,
            "layer_seconds": now - prior_time,
            "elapsed_seconds": now - start_time,
            "working_set_bytes": rss,
        }
        timings.append(row)
        prior_time = now
        print(json.dumps(row), flush=True)

    def observe_scale(label: str, row: dict[str, float | int]) -> None:
        scale_audit.append({"tensor": label, **row})

    model_path = args.checkpoint / "model.safetensors"
    with safe_open(model_path, framework="pt", device="cpu") as handle:
        model = StreamingBitNet(handle, geometry=BitNetGeometry())
        final_hidden = model.run(
            token_ids, 30, CAPTURE_LAYERS, capture, progress,
            kv_profile=profile, scale_observer=observe_scale,
            cache_transform=None if profile is None else cache_audit)
        logits = chunked_vocab_logits(handle, final_hidden)
    peak_rss = max(peak_rss, process.memory_info().rss)
    torch.save(final_hidden, destination / "final_hidden.pt")
    np.save(destination / "last_token_logits.npy", logits)
    np.savez_compressed(
        destination / "last_token_observables.npz",
        last_token_hidden=final_hidden[-1].float().numpy(),
        top20_token_ids=np.argsort(logits)[-20:][::-1].astype(np.int32),
        top20_logits=np.sort(logits)[-20:][::-1].astype(np.float32),
        target_token_id=np.asarray([context["target_token_id"]], dtype=np.int32),
        target_token_logit=np.asarray(
            [logits[context["target_token_id"]]], dtype=np.float32),
    )
    if profile is not None:
        np.savez_compressed(
            destination / "stored_kv_scale_codes.npz",
            K=np.concatenate(cache_audit.scale_codes["K"]).astype("<u2"),
            V=np.concatenate(cache_audit.scale_codes["V"]).astype("<u2"),
            fractional_bits=np.asarray(
                [profile.kv_scale_fraction], dtype=np.uint8),
            storage_bits=np.asarray([profile.kv_scale_width], dtype=np.uint8),
        )

    if args.profile == "BASE_FP":
        metrics = {
            "final_hidden_relative_rmse": 0.0,
            "final_hidden_cosine": 1.0,
            "last_token_hidden_relative_rmse": 0.0,
            "last_token_hidden_cosine": 1.0,
            "target_token_logit_delta": 0.0,
            "top1_preserved": True,
            "top5_exact_set_preserved": True,
            "top5_overlap_fraction": 1.0,
            "kl_reference_to_candidate": 0.0,
            "js_divergence": 0.0,
            "selected_layers": [],
        }
        cache_result = None
    else:
        base_hidden = torch.load(
            base / "final_hidden.pt", map_location="cpu", weights_only=True)
        base_logits = np.load(base / "last_token_logits.npy")
        metrics = {
            "final_hidden_relative_rmse": relative_rmse(final_hidden, base_hidden),
            "final_hidden_cosine": cosine(final_hidden, base_hidden),
            "last_token_hidden_relative_rmse": relative_rmse(
                final_hidden[-1], base_hidden[-1]),
            "last_token_hidden_cosine": cosine(
                final_hidden[-1], base_hidden[-1]),
            "target_token_logit_delta": float(
                logits[context["target_token_id"]] -
                base_logits[context["target_token_id"]]),
            "selected_layers": sorted(layer_metrics, key=lambda row: row["layer"]),
        }
        metrics.update(distribution_metrics(logits, base_logits))
        cache_result = cache_audit.finalize(profile.kv_scale_fraction)

    kv_scale_rows = [
        row for row in scale_audit if row["tensor"].endswith((".K", ".V"))]
    scale_counts = sum(int(row["scale_count"]) for row in kv_scale_rows)
    elapsed = time.perf_counter() - start_time
    result = {
        "evidence": "REAL-MODEL-VALIDATED/v0.3-gate-a",
        "status": "PASS",
        "claim_scope": (
            "hidden-state, selected-layer attention/block, and tied-logit "
            "distortion; not perplexity, task accuracy, or generation quality"),
        "prompt_id": args.prompt_id,
        "context_length": args.context_length,
        "target_token_id": context["target_token_id"],
        "token_ids_sha256": context["token_ids_sha256"],
        "execution_profile": args.profile,
        "profile_contract": None if profile is None else asdict(profile),
        "equivalent_required_profiles": (
            ["PACKED5_RAW_UQ4_8", "PACKED5_PAGE64_UQ4_8",
             "PACKED5_PAGE128_UQ4_8"]
            if args.profile == "PACKED5_PAGE128_UQ4_8" else [args.profile]),
        "reference_run": None if base is None else str(base.resolve()),
        "write_side_policy": (
            "codes selected using high-precision absmax; dequantization uses "
            "the rounded stored scale"),
        "scale_audit": {
            "records": scale_audit,
            "kv_scale_count": scale_counts,
            "kv_underflow_count": sum(
                int(row["underflow_scale_count"]) for row in kv_scale_rows),
            "kv_overflow_count": sum(
                int(row["overflow_scale_count"]) for row in kv_scale_rows),
            "kv_underflow_rate": (
                sum(int(row["underflow_scale_count"]) for row in kv_scale_rows) /
                scale_counts if scale_counts else 0.0),
            "kv_overflow_rate": (
                sum(int(row["overflow_scale_count"]) for row in kv_scale_rows) /
                scale_counts if scale_counts else 0.0),
        },
        "cache_codec_audit": cache_result,
        "checkpoint": str(args.checkpoint.resolve()),
        "checkpoint_model_sha256": sha256(model_path),
        "elapsed_seconds": elapsed,
        "peak_observed_working_set_bytes": peak_rss,
        "timings": timings,
        "metrics": metrics,
        "python": platform.python_version(),
        "torch": torch.__version__,
    }
    (destination / "run.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": "PASS",
        "profile": args.profile,
        "prompt": args.prompt_id,
        "context_length": args.context_length,
        "elapsed_seconds": elapsed,
        "metrics": metrics,
    }, indent=2), flush=True)


if __name__ == "__main__":
    main()
