# ADR-0032: The model plans what to look up

- **Status:** Accepted (owner's request, 2026-10-26)

## Context

Questions about the owner's records were searched by fixed phrase rules: word lists decided the time window, the places to look and the people. The model only answered from what those rules found. "What have I got on for the next week?" got "I couldn't find matching records": "got" read as received mail, "got on" wasn't a calendar phrase, and "the next week" became next calendar week, searched for messages sent in the future. Each new phrase fixed one wording and missed the next. The owner asked for Aegis to understand what they mean rather than match phrases.

## Decision

Before anything is searched, the local model reads the owner's question and writes a **search plan** as short JSON: whether the answer is in the owner's records at all, where to look (calendar and reminders, messages, mail), **when** as one standard phrase ("tomorrow", "next week", "thursday", "the next 7 days"), the people and topics named, and received or sent. The model normalises the wording ("Thursday arvo", "the coming seven days", "a fortnight"); code turns the standard phrase into exact dates, because date arithmetic is where a small model slips and code doesn't.

- **Input:** the owner's own words and today's date only. No message, email, event or memory text is ever part of the plan's input, so collected content cannot steer a search.
- **Checks:** only known places; the time only from the standard phrases; people only if their words are in the owner's question; topics short single lines; anything else is dropped. An unusable reply, a cancelled job or a busy model leaves the phrase rules (AskQuery, AskSelection) to decide, as before.
- **Search:** the plan sets the calendar and message windows (a time still to come searches messages over the fortnight up to now), whether the calendar is read, the source and direction, and search terms (with the rules' keywords for recall). People the model names may be relations ("the plumber"), so they only help ranking: who sent what is still resolved from the owner's words against Contacts. A plan that says the answer isn't in the owner's records sends the question to the conversation without searching.
- **Ambiguity:** "next week" and "the next 7 days" are used loosely for each other by people and the model alike, so both search from now to the end of next week; "last week" and "the last 7 days" from the start of last week to now. With only messages or mail to search, a bare weekday is the one just gone.
- **Cost:** one short job (at most 120 tokens) before each question that reaches a search, on the same turn, so a new question cancels it. Quick answers, memory and commands don't run it.

## Consequences

- Wordings no rule anticipated are understood, as far as the model understands them. `search-eval` (Packages/ModelRuntime) scores the real model on synthetic questions: on 2026-10-26 with Qwen3.5-9B, 40/40 on the tuning set and 20/20 on 20 held-out wordings (17/20 before two general fixes in code and one prompt line).
- About 1.5 seconds more per question (median; at most about 3 s). The phrase rules stay as the fallback and are no longer where wording is fixed.
- The model only chooses what to read. Answers are still checked against their sources (ADR-0020), and nothing it plans can act.
