# Universal rules — operator README

`templates/universal-rules.md` is the canonical universal-rules block. Its full text is pasted verbatim into every customer agent's `systemPrompt` at Stage 4 of the `/base-agent` skill, under the `=== UNIVERSAL_RULES ===` delimiter, before the agent's identity block, the brain-doc, the PROCEDURES layer, and the minimal tool note.

The 16 rules in that file have been tested in production agents. Do not edit them casually. Updates propagate to every future customer agent built through `/base-agent`.

**Why this README is separate.** The assembler at Stage 4 pastes `universal-rules.md` byte-for-byte into the live agent's runtime system prompt. Any operator commentary inside that file becomes part of what the live agent reads as instructions — it pollutes the agent's first instructions with file-management talk instead of the receptionist rules. Keep operator/maintainer notes here, in this README. Keep the rules-only content there.
