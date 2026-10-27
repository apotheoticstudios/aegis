# ADR-0021: Owner facts and learned sender identities

Status: accepted for the owner-requested follow-up in #249, 2026-10-18.

## Decision

Save ordinary factual statements and preferences made directly to Aegis, plus explicit remember commands, in the existing local memory file. Keep the owner's words rather than inventing extracted facts. Questions, hypothetical statements, quotations, imported-message text and transient chatter are not automatic facts. Only complete handle/name assertions create identity corrections. Collected messages, model answers and past exchanges never create a sender correction.

Interpret a note such as an invented phone number followed by “is Morgan Example” as an owner correction. Apply it over the corresponding handle in the Contacts snapshot, using the existing AU phone and email normalization. Reuse a contact ID only when the complete name identifies exactly one card. Equal-name cards remain ambiguous; a new identity uses a stable local handle-derived ID. Outgoing-event and owner-handle rules still apply. Forgetting a note removes its correction and restores the underlying Contacts result.

Use the corrected index throughout naming, brief input, retrieval, meeting prep and spoken answers. Protect both the original Contacts names and learned names from cloud hand-off. An existing brief with an affected citation is shown as a source quote with the corrected sender; the original stored draft stays intact. Refresh the panel's brief and loaded source headings after a memory change.

No wire schema or API signature changes: existing MemoryNote/MemoryBook files load as before. No Apple Contacts writes, new dependencies, network access or logging of personal data. The app continues to store memory in its private local folder. All tests use invented fixtures.

## Persistence and limits

Acknowledge a new fact or correction only after an atomic memory save succeeds; restore the previous in-memory state on failure. Durable notes have no age expiry. Preserve existing notes when the 500-note store is full and explain the limit instead of silently evicting a fact. Notes accept the same 500-scalar maximum as an owner request. Recent conversation history keeps its existing bounds and is separate from sender evidence. Explicit remember/forget/list and the memory list remain available.

## Consequences

Facts and identity corrections survive app restarts and ending a conversation. Automatic fact recognition is deterministic, so ambiguous language may still need a clearer statement or an explicit “remember that…”. Existing non-identity facts are not inferred into contact mappings. This adds work only on owner requests or existing source processing, not an always-running model.

## Amendment (2026-10-27): the same person saved twice

A number on several Contacts cards that all carry the same name (ignoring case and spacing), or no name, is one person saved twice: it resolves to the first card's ID, so rules and history stay together. Cards with different names sharing a number stay ambiguous and are never guessed; the owner names them once ("+61… is Name").
