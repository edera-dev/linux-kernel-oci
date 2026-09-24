# How the posted review reads

Shared by the `pr-review` and `test-coverage-review` skills. Both link here so
the rule has one copy. Each skill says what its section of the review
contains; this file says how much of it there is and how it reads.

The analysis behind a review can be as exhaustive as it needs to be. The text
posted to the pull request is not. Write it for the engineer who authored the
change: they already know the codebase and the diff, and the section tells
them what they need to know and what, if anything, they need to change.

## What stays out

- Narration of the investigation. Do not say what you went through, checked,
  read, traced or verified; state the conclusion. The exception is a fact
  about the checking that changes what the author should do with a finding,
  such as a reproduced failure or a test that could not be run.
- A record of what was inspected. Do not list every file, function, branch or
  test you looked at. A file or symbol appears where it supports a finding and
  nowhere else.
- A restatement of the pull request, or a description of code the diff
  already shows.
- Praise and filler. "Looks good overall", "well thought out", "testing looks
  right", "the approach is sound" carry no information. The clean verdict is
  one specific sentence about what the change is and what covers it.
- The same conclusion twice. When the summary says a finding should be fixed
  before merge, the finding does not say it again.
- Implementation detail that does not change what the author does next.
- Evidence beyond what the finding needs. The full proof goes in only when the
  finding would otherwise be ambiguous or contested; otherwise the smallest
  reference that lets the author verify it.
- Dramatic language, metaphors, clever phrasing, and the transitions and
  commentary that mark generated text.

## Limitations, once

When something could not be run or reached in the environment the review ran
in, say so once, in the opening summary, in one sentence:

> I could not run the manifest tests in this environment; those changes were
> reviewed statically.

Do not repeat the qualification on each finding it touches. A finding whose
chain has one unverified link names that link in the finding, in a clause,
and that is the whole of it.

## Size

Length comes from the number and weight of real findings, not from the amount
of analysis done. The usual limits, exceeded only when there are several
independent substantive findings:

- the opening summary or verdict: one to three sentences;
- one finding or one gap: under 150 words;
- the Test Coverage section: under 150 words;
- the whole review: under 500 words.

If the same point can be made accurately in three sentences instead of ten,
use three. Shorter comes from leaving things out, not from packing several
ideas into one long sentence.

## Before publishing

Remove investigation narration, reasoning stated twice, file references the
finding does not need, descriptions of code visible in the diff, evidence that
does not change the conclusion, and any sentence whose only purpose is to
sound thorough. Then check the sizes above. What remains should tell the
author what they need to know and what, if anything, they need to change.
