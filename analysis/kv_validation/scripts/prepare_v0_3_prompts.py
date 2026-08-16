#!/usr/bin/env python3
"""Create the frozen eight-prompt input set for KV-cache v0.3 Gate A.

All prompts are original natural prose, tokenized once with the checkpoint's
tokenizer, and truncated without repetition.  Every prompt supplies context
128; engineering and observatory also supply context 512.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from tokenizers import Tokenizer


PROMPTS = {
    "engineering": """
An engineer is reviewing a small FPGA accelerator intended to serve attention
requests from a compact language model. The board has limited external memory
bandwidth, so the design stores keys and values in low precision and keeps the
metadata in separate scale buffers. Before changing the hardware, the engineer
checks how scale granularity affects logits, probability distributions, and the
weighted value output. She also records every assumption about alignment,
burst length, overflow, and back pressure. During verification, long requests
are followed immediately by short requests, memory responses are delayed at
random, and malformed transfers must produce explicit errors. The objective is
not to claim model accuracy from synthetic vectors. It is to find the simplest
architecture whose numerical behavior remains stable on real activations and
whose timing report is credible on the target Artix device. Once the evidence
is collected, the team will decide whether the next block should accelerate
softmax, stream the value cache, or improve the existing query-key scheduler.

On Monday she begins by drawing the memory map on a whiteboard. Payload pages
occupy one region, scale words occupy another, and a compact table records the
aligned start of every page. She asks a colleague to read the drawing without
any verbal explanation. He immediately notices that a checksum covering only
the compressed bytes cannot detect a scale-plane corruption, so they amend the
contract before writing code. The checksum will include the stable part of the
header, the payload, and exactly the scale slice used by that page. Offset
tables receive their own checksum because a plausible but wrong offset can
redirect an otherwise valid decoder. These decisions are copied into both the
software reference and the hardware notes.

Tuesday is devoted to measurements. The engineer records accepted read beats,
cycles when the data FIFO is empty, decoder stalls, raw-page fallbacks, and MAC
issue cycles. The counters reveal that a wider bus alone cannot repair bubbles
caused by short bursts and late metadata. A pair of page buffers looks more
promising: while one buffer feeds arithmetic, the other can receive and verify
the following page. She keeps the first implementation intentionally modest,
with a 128-bit interface and sixteen arithmetic lanes, because the target board
must remain a first-class configuration rather than a reduced demonstration.

On Wednesday the verification plan is made deliberately awkward. Requests of
one, seven, sixty-three, sixty-four, and sixty-five tokens exercise partial
groups. Boundaries around one hundred twenty-eight, five hundred twelve, and
four thousand ninety-six tokens are included too. Randomized back pressure can
pause either the payload or scale path. A long request is followed immediately
by a short one so stale counters cannot hide in the state machine. One test
flips a header bit, another damages a scale bit, and a third changes an offset.
Each fault must produce the same sticky error identity and must prevent any
partially decoded vector from becoming architecturally visible.

Thursday brings synthesis. The automatic multiplier mapping is compared with
an explicit shift-and-add construction under identical pipeline boundaries.
The engineer refuses to infer a conclusion from source appearance: only the
placed design can show the resource and timing trade. She also checks that the
score store is inferred as synchronous block memory rather than thousands of
distributed RAM cells. Critical paths are copied verbatim from the reports,
and estimated frequency is labeled separately from routed timing. At the end
of the week, every generated file is hashed, the exact command log is saved,
and the remaining hypotheses are listed beside the evidence needed to test
them on a different checkpoint.
""",
    "observatory": """
Just before dawn, a student walked up the narrow stairs of an old observatory
with a notebook, a thermos, and a list of stars to measure. Clouds had covered
the valley all week, but the air was finally clear and the dome opened without
a sound. Her mentor asked her to begin with a familiar calibration star, then
move slowly toward the faint object near the eastern horizon. Between exposures
they compared timestamps, checked the tracking motor, and wrote down small
changes in temperature. A fox crossed the service road below, paused in the
headlights, and disappeared among the pines. By sunrise the final image was not
spectacular, yet it contained the clean signal they needed. The student saved
the raw frames, copied the observing log, and left a careful note for the next
shift explaining which measurements were trustworthy and which should be
repeated when the weather allowed another quiet night.

The following afternoon she returned to inspect the files. One exposure had a
thin diagonal trail from a satellite, while another showed a small jump caused
by wind pressing against the dome. Rather than discard anything immediately,
she marked each anomaly in a table and kept the untouched images beside the
calibrated versions. Her mentor explained that a beautiful picture can be less
useful than an ordinary one with a complete history. Together they measured
the dark current, compared flat fields from two evenings, and found that a
loose cable had added a repeating pattern to the lower corner of the sensor.

That night the weather changed quickly. High clouds crossed the western sky,
so the team shifted to brighter targets and shortened every exposure. The
student read the checklist aloud before each sequence: confirm time, focus,
filter, guide star, and file name. A visiting teacher brought three pupils into
the control room. They expected dramatic colors but instead saw pale grayscale
frames and columns of numbers. She showed them how many dim points become a
map when their positions are compared across time, and how a small uncertainty
written honestly is more valuable than a confident guess.

Near midnight the tracking motor began to hesitate. The telescope could still
move, but the error grew whenever it crossed one narrow band of the sky. The
mentor chose not to force the mechanism. They parked the instrument, closed the
dome, and used the remaining hours to process the previous observations. The
student aligned the images, rejected damaged pixels, and graphed brightness
against air mass. A single point seemed unusually bright until she checked the
log and discovered that the exposure had started before the shutter was fully
settled. The correction was simple because the record was precise.

At the end of the run she wrote a longer handoff than usual. It described the
motor symptom, the cable that had been reseated, the calibration files, the
cloud intervals, and the exact frames excluded from the preliminary result.
She did not announce a discovery. Instead she proposed two observations that
would distinguish an interesting change in the faint object from an ordinary
instrument effect. Weeks later, another observer followed those instructions
under better conditions. The signal remained, and the student's patient notes
made the comparison possible.
""",
    "kitchen": """
At a neighborhood cooking class, the instructor teaches eight beginners to
make vegetable dumplings without relying on a rigid recipe. She first asks
everyone to taste the cabbage, because a young head holds more water than one
stored through winter. The students salt and rest the chopped leaves, squeeze
them gently, and weigh the liquid that drains away. Ginger, mushrooms, sesame
oil, and white pepper are added in small stages. Each bowl is labeled so the
class can compare a mild filling with one that is richer and more aromatic.
When folding begins, several wrappers tear. The instructor slows down and
shows how a dry edge cracks while an overfilled center prevents a clean seal.
Soon the table holds rows of imperfect but sturdy crescents. Half are steamed
over cabbage leaves and half are browned in a skillet before a little water is
added. While they cook, the class mixes black vinegar with sliced scallion and
discusses which observations belong in a useful recipe: pan temperature,
resting time, approximate moisture, and the signs that indicate doneness.
Nobody claims that one batch is universally best. They record what happened,
share the dumplings, and leave enough detailed notes for the next class to
repeat the comparison.
""",
    "council": """
The town council meets in the library to discuss a proposal for a safer route
between the train station and two nearby schools. Residents have submitted
maps, photographs, traffic counts, and letters describing difficult crossings.
The transportation planner explains three alternatives: a protected bicycle
lane, a wider sidewalk with raised intersections, and a lower-cost plan that
changes signals but leaves the road geometry intact. Shop owners worry about
loading access, parents emphasize afternoon congestion, and a wheelchair user
points out places where steep curb ramps collect rainwater. Instead of taking
an immediate vote, the chair asks staff to publish the assumptions behind the
cost estimates and to measure weekend traffic as well as weekday peaks. A
temporary installation will be tested for six weeks using removable barriers.
Emergency services, bus drivers, delivery workers, students, and residents are
invited to report specific problems through a public form. The final memo must
separate observed changes from forecasts, list any injuries or near misses,
and explain how weather affected the counts. The meeting ends with disagreement
about details but broad support for gathering evidence that everyone can audit.
""",
    "marine_fieldwork": """
A marine ecology team arrives at a sheltered bay during the lowest tide of the
month. Their task is to survey eelgrass without trampling the fragile beds they
intend to measure. Two researchers place numbered markers along the shoreline,
while a third checks salinity, temperature, and dissolved oxygen. The team uses
a small camera frame lowered from a kayak, taking images at fixed intervals
rather than selecting only the densest patches. In the shallows they find crab
shells, drifting algae, and areas where recent storms have shifted the sand.
Every unusual observation is photographed with a scale and matched to a time
and location. Back at the field station, the images are assigned random names
before coverage is estimated, reducing the chance that expectations influence
the scoring. One memory card reports an error, but duplicate copies made on the
boat preserve the original files. The researchers publish their sampling path,
excluded frames, calibration checks, and uncertainty. The survey cannot prove
why the grass changed, yet it provides a reliable baseline for the next season
and identifies two places where additional current measurements would be most
informative.
""",
    "museum_letter": """
The curator of a small industrial museum writes to a retired machinist whose
family has offered a box of workshop notebooks. She explains that the museum is
interested not only in polished drawings but also in corrections, shopping
lists, and notes about failed repairs. Those ordinary marks can reveal how work
was actually organized. Before accepting the donation, the curator asks about
ownership, privacy, and whether any pages should remain closed for a period of
time. She proposes scanning the notebooks in their existing order, recording
dimensions and paper condition, and returning a digital copy to the family.
The letter avoids promising that every page will appear in an exhibition.
Instead it describes how a catalog entry, preservation folder, and searchable
index would make the material available to future researchers. She also asks
whether the machinist would be willing to record an interview about unfamiliar
abbreviations and the people named only by initials. A week later he agrees,
provided that the museum preserves his mistakes along with his successful
designs. The curator welcomes that condition because an honest working record
is more valuable than a tidy story assembled after the fact.
""",
    "mountain_rescue": """
Before the summer hiking season, a volunteer rescue team practices responding
to an injured walker on a wooded ridge. The exercise begins with an incomplete
phone message: a sore ankle, fading battery, and a photograph that shows rocks
but no recognizable landmark. One group studies maps and recent trail reports,
another prepares medical equipment, and a radio operator records every decision
with its time. They estimate a search area but keep alternative locations open
until a ranger recognizes a distant fire tower in the photograph. On the trail,
the volunteers move at a sustainable pace and pause whenever radio contact is
lost. The simulated patient is found cold and anxious beside a junction whose
sign has fallen. After splinting the ankle, the team chooses a longer descent
that avoids wet stone. During the review, nobody is congratulated for guessing
quickly. The useful lessons concern battery conservation, precise descriptions,
equipment placement, and the missing sign. The team updates its checklist and
sends the trail hazard to the park office, clearly separating the exercise's
invented injury from the real maintenance problem discovered along the route.
""",
    "oral_history": """
An oral historian visits a riverside neighborhood to interview a baker who has
worked on the same street for forty years. The recorder is placed between them,
but the conversation begins only after they review consent and the baker chooses
which parts may be public. He remembers predawn deliveries, winter floods, and
the arrival of families from several countries who introduced new breads to the
shop. Dates are sometimes uncertain, so the historian asks about nearby events,
school terms, and changes in bus routes rather than forcing an exact year. When
the baker names former employees, she marks those passages for later permission.
Traffic interrupts one answer and a refrigerator motor masks another; both gaps
are noted instead of silently repaired. After transcription, the baker receives
the text and corrects the spelling of names while leaving his spoken grammar
unchanged. Photographs and municipal records are used to check locations, but
they do not replace his perspective. The finished archive includes the audio,
transcript, corrections, restrictions, and a short account of how the interview
was conducted, allowing future listeners to understand both the memories and
the conditions under which they were recorded.
""",
}


LONG_PROMPTS = {"engineering", "observatory"}
CONTEXTS = (128, 512)


def token_hash(token_ids: list[int]) -> str:
    payload = json.dumps(token_ids, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--tokenizer", type=Path,
        default=repo.parent / "bitnet-b1.58-2B-4T" / "tokenizer.json")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "prompts_and_token_ids.json")
    args = parser.parse_args()

    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    records = []
    seen_hashes: set[str] = set()
    for prompt_id, source_text in PROMPTS.items():
        text = " ".join(source_text.split())
        token_ids = tokenizer.encode(text).ids
        required = 512 if prompt_id in LONG_PROMPTS else 128
        if len(token_ids) <= required:
            raise AssertionError(
                f"{prompt_id} has {len(token_ids)} tokens; need target after {required}")
        contexts = {}
        for context in CONTEXTS:
            if context == 512 and prompt_id not in LONG_PROMPTS:
                continue
            current = token_ids[:context]
            digest = token_hash(current)
            if digest in seen_hashes:
                raise AssertionError("prompt contexts are not genuinely distinct")
            seen_hashes.add(digest)
            contexts[str(context)] = {
                "token_ids": current,
                "token_ids_sha256": digest,
                "target_token_id": token_ids[context],
                "unique_context_tokens": len(set(current)),
            }
        records.append({
            "prompt_id": prompt_id,
            "text": text,
            "full_token_count": len(token_ids),
            "contexts": contexts,
        })

    result = {
        "evidence": "REAL-MODEL-INPUT/tokenizer",
        "checkpoint": "microsoft/bitnet-b1.58-2B-4T",
        "construction": (
            "eight independent original natural-prose prompts; truncate once; "
            "no repeated token cycle"),
        "fixed_seed": 20260816,
        "context_128_prompt_count": len(records),
        "context_512_prompt_count": len(LONG_PROMPTS),
        "prompts": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        row["prompt_id"]: {
            "full_tokens": row["full_token_count"],
            "contexts": {
                key: value["unique_context_tokens"]
                for key, value in row["contexts"].items()
            },
        }
        for row in records
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
