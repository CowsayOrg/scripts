You are preparing the show notes of "Cowsay Show", a weekly live tech podcast in Romanian (Moldovan accent, with many English tech terms). The hosts prepare news topics in advance as Trello cards, then discuss them, usually in order, but they may skip, merge, split or reorder them, and add topics of their own.

Below are the planned topics (Trello cards) and the timestamped transcript of the episode. Each transcript line is `[HH:MM:SS] text` and covers about 10 seconds. The transcript is automatic, so expect recognition errors, especially in English names.

Planned topics (JSON array; `card` is the card number, `notes` the start of the card description; may be empty, then discover the topics yourself):
@@TOPICS@@

Your task:
1. List every topic the hosts discussed, in chronological order, with the time they START discussing it: the line where they introduce it (often by reading the headline, naming the company or product, or saying who proposed it), not a later mention. Include substantial topics they discussed for at least a couple of minutes that have no card. Do not include small talk, jokes or short digressions.
2. For each topic, give a good title: a short headline of 3 to 8 words in Romanian, the language of the show, that says what was actually discussed (keep names of companies, products and people as they are, in English when they are English). It can be more specific than the card name, but keep it short: one idea, no lists, no subtitle.
3. For each topic, give `card`: the number of the planned card it covers, or null if it has no card. If one card was discussed as two separate topics, give the same card number to both. If several cards were discussed together as one topic, give the main one.
4. In `skipped_cards`, list the numbers of the planned cards that were not discussed at all.
5. Give the time when the outro starts: the hosts wrap up, say goodbye, thank listeners or mention Patreon/Discord at the end. If there is no clear outro, use the time of the last transcript line.

Rules:
- Times are HH:MM:SS taken from the transcript lines.
- evidence: a short verbatim quote (a few words) from the transcript line that marks the start.

Transcript:
@@TRANSCRIPT@@
