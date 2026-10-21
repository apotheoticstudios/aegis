# ADR-0020: Keep identities and conversation evidence separate

Status: accepted for issue #247 (owner-authorized accuracy fix, 2026-10-16).

## Decision

Use reader-supplied sender identities, source-qualified conversation keys and original cited records in brief and spoken-answer inputs. Names mentioned inside a body are not sender identities. Different contact IDs with an equal name or shared handle remain ambiguous. Resolve full-name queries before first names; ambiguous names require clarification. Sender-specific retrieval cannot backfill another person's records. Questions about a mentioned person may still retrieve the original speaker's statement.

A brief cannot use an uncited same-thread record as evidence. Separate conversations split into source quotes; wording that blends known people is replaced by the original sender's quote. Calendar invitees and event status are supplied separately from any claim of attendance. General conversation receives original brief sources, rather than treating a generated summary as factual evidence. A rejected cited answer stays rejected instead of retrying through unchecked chat. Internal identity labels cannot be spoken or published.

A brief rejected solely for excess urgent items has its priority labels capped deterministically in model order, then passes the same full publication checks again. Text, citations and every other field are preserved, including evidence of attempted actions. There is no second model call. Unsafe or ungrounded failures do not retry through chat.

No Event, Brief or XPC wire schema changes; no new dependency, collection, network access or logging. Tests and model comparisons use invented records only. Models still load on demand and unload through the existing idle timeout.

## Local model comparison

Compared the current pinned Qwen3.5-9B-MLX-4bit with Qwen3.5-27B-4bit, revision `45797d2985a12c55e6473686e9ea91b95e959553`, using the same seven invented answer cases and a mixed-person brief in `accuracy-run`. The 27B public model download was explicitly authorized; no collected data was used or sent anywhere.

On the 24 GB Apple Silicon test Mac, the 9B process peaked at 6.28 GB; the 27B process peaked at 17.80 GB (decimal, whole-process footprint). Warm answer generation was about 2.2–3.2 seconds versus 7.3–16.8 seconds. Brief generation was 19.0 versus 44.0 seconds. These are small diagnostic cases, not a general accuracy benchmark or a maximum-context memory guarantee.

Both models produced an ambiguous cake attribution in the raw brief. The 9B misplaced a calendar citation; the 27B correctly placed it but exposed an internal identity label in a different answer. Keep the 9B default: the small quality difference does not justify the additional memory and spoken-answer delay on this Mac. Identity, citation and source-quote checks are necessary regardless of model size.

The full synthetic held-out day (seed 7) publishes six items with zero detected wrong-person attributions, unsupported facts, invalid citations or followed instructions. It recalls 5/7 important communications and ranks one noise notification high priority, so the independent scorer still fails recall and noise thresholds. This is a recorded limitation, not a passing held-out result; the changes do not solve all relevance or urgency errors.

## Consequences

Duplicate contact cards without an explicit shared identity can now require clarification. Conservative quotes can be less fluent, and a rejected answer can require rephrasing. Added metadata consumes some of the existing bounded context budget. These checks reduce demonstrated attribution failures; they do not prove semantic truth or eliminate every model error. Real-data acceptance remains with the owner.
