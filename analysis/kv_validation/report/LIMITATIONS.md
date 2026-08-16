# Limitations

> This list belongs to the original validation pass. The authoritative current
> limitations and unverified hypotheses are maintained in
> `V0_2_AUDIT_ADDENDUM_REPORT.md` and `../../../docs/KV-IP.md`.

1. `[REAL-MODEL-VALIDATED]` The layer-streaming reference completed the full
   30-layer checkpoint at contexts 128 and 512, capturing five layers. Contexts
   1024/2048/4096 remain `NOT_TESTED` because of CPU time; they did not fail.

2. The context-512 sequence extends the same deterministic recorded token
   pattern used at context 128. It is a context holdout for the predictor
   experiment, not a prompt-independent or dataset-level validation.

3. The custom runner is source-matched to the checkpoint arithmetic and one
   real layer is bitwise equal to the pinned Transformers implementation. It
   is not an optimized inference runtime, an RTL bit-exact reference, or an
   independent implementation of every decoder layer.

4. Quantization results measure QK/logit and attention-output tensor
   distortion. They do not establish model accuracy, perplexity, generation
   quality, or an acceptable deployment threshold.

5. `[SOFTWARE-SYNTHETIC]` Gaussian, Laplace, Student-t, sparse 0.1%×25, and
   1%×10-outlier sweeps remain useful stress tests, but they are not model
   tensors. Synthetic and real-model results are labeled separately.

6. `[SOFTWARE-FIXED-POINT]` Q8.8 reconstruction is not a cycle/bit-accurate
   implementation model. Write-side scale calculation, rounding, saturation,
   multiplier truncation, and accumulator policies still require an RTL
   contract.

7. The V `sigma^2/N_eff` predictor transfers poorly from context 128 to 512;
   it must not be used as an error guarantee or to select V precision. The K
   first-order predictor is useful for trend/ranking at INT4/INT5, not a bound.

8. The actual model has `HEAD_DIM=128`; the deliberately small baseline RTL
   defaults to `HEAD_DIM=64`. Equal-dimension storage comparisons are kept
   separate from capacity comparisons that change head dimension.

9. `[RTL-SIMULATED]` Icarus covers four HEAD_DIM/AXI combinations, while XSIM
   currently repeats the first-class HEAD_DIM64/AXI128 boundary/error suite.
   Scale-plane synchronization and underflow cannot be tested until the v0.2
   reader/FIFO exists.

10. `[VIVADO-POST-SYNTH]` Utilization and timing are out-of-context synthesis
    results for `xc7a100tcsg324-1`. Timing is pre-place-and-route estimated;
    it is not routed timing closure, a bitstream, or a board measurement.

11. `[THEORETICAL]` Storage/beat arithmetic is exact for the stated layouts,
    but burst efficiency and the Amdahl roadmap depend on MIG arbitration,
    DDR behavior, cache contention, and still-unimplemented softmax/V blocks.

12. Hadamard and deterministic dither remain disabled. The exact historical
    `G_B`/CRC/LFSR mapping is deliberately `TODO`; no deterministic generator
    is claimed to emulate IID randomness.
