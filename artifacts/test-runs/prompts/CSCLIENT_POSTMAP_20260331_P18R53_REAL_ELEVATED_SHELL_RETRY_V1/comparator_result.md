# Comparator Result

Comparator execution status: `not run`

Why the comparator did not run:
- The shell gate failed before any direct ETW preflight could be attempted.
- No traced rerun was allowed.
- No fresh traced fallback raw artifact exists for this run.
- No dedicated raw artifact anchor appropriate for the requested comparison workflow exists in this working copy.

Configured comparison window preserved:
- core: `0x1F29-0x1FF9`
- optional extension: `0x1FFA-0x2009`

Result fields:
- `comparison_window_used = none`
- `first_exact_divergence_offset = unresolved`
- `0x09 / 0x09 / 0x09 / 0x0D framing = unresolved`
- `later raw 0x27 restart through 0x2009 = unresolved`
