# Fixed-Point Softmax Architecture Contract v0.1

Status: architecture frozen; final binary points remain tunable until real-model validation.

Pipeline:
1. receive valid logits
2. compute/subtract row maximum
3. clamp negative delta to LUT domain
4. exponential lookup/interpolation
5. wide positive accumulation
6. normalize sum to reciprocal input interval
7. reciprocal seed LUT
8. one Newton-Raphson refinement (NR1)
9. multiply exp value by reciprocal
10. round/saturate to attention output format

Required invariants:
- subtract-max is mandatory
- masked entries contribute exactly zero
- accumulation must not overflow at maximum supported context
- reciprocal path must be monotonic over the valid interval
- output probabilities are non-negative
- sum-of-probabilities error is measured for every golden vector
- no final Q formats are frozen until real-model score/entropy statistics arrive

Candidate analysis format only:
- delta/logit: Q6.10
- exp LUT output: Q1.15
- LUT domain: [-16, 0]
- 257 reference entries

The candidate table is for numerical screening, not yet an RTL ABI.
