You are preparing the show notes of "Cowsay Show", a weekly live tech podcast in Romanian (Moldovan accent, with many English tech terms). The hosts go through a list of news topics prepared in advance on a Trello board, usually in order, but they may skip, reorder or add topics.

Below are the planned topics and the timestamped transcript of the episode. Each transcript line is `[HH:MM:SS] text` and covers about 10 seconds. The transcript is automatic, so expect recognition errors, especially in English names.

Planned topics (JSON; may be empty, then discover the topics yourself):
@@TOPICS@@

Your task:
1. For every planned topic, find the time when the hosts START discussing it: the line where they introduce it (often by reading the title, naming the company or product, or saying who proposed it), not a later mention. If a planned topic was not discussed, mark it skipped and set start to null.
2. Add any other substantial topic the hosts discussed for at least a couple of minutes that is not in the planned list, with planned set to false, a short title in the language they used, and link set to null. Do not add small talk, jokes or short digressions.
3. Give the time when the outro starts: the hosts wrap up, say goodbye, thank listeners or mention Patreon/Discord at the end. If there is no clear outro, use the time of the last transcript line.

Rules:
- Copy planned titles and links exactly, character for character, including any "[Name]" prefix.
- Times are HH:MM:SS taken from the transcript lines.
- Return topics in chronological order of their start.
- evidence: a short verbatim quote (a few words) from the transcript line that marks the start; empty for skipped topics.

Transcript:
@@TRANSCRIPT@@
