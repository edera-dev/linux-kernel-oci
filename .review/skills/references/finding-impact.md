# What a finding has to establish

Shared by the `pr-review` and `test-coverage-review` skills. Both link here so
the rule has one copy. Each skill adds only what is specific to it.

A finding answers three questions. Miss the third and the reader has the defect
without a reason to care about it.

1. What is wrong in the code.
2. What behaviour that produces at runtime.
3. What that behaviour does to an operator, a consumer of what this repository
   produces, a build, its data, its performance, or a security boundary.

Trace it in that order: **code or configuration condition, then actual
behaviour, then concrete operational consequence.**

Stopping at "the configured value is ignored" gives the mechanism and leaves
out the reason you gave the finding its severity. Carry it one step further:

> The fragment sets the symbol but is merged before the base config that clears it, so the published kernel has the option off. Anything that pins this tag and relies on the option gets a kernel without it, and neither the build nor the image metadata says so.

## Name the thing that suffers

The consequence names what is affected and what happens to it. Pick the
category that actually applies and say it once. Do not walk the list.

- Availability or stability of something that was running
- A build, job or release that fails, or that succeeds having produced the
  wrong thing
- Data loss or corruption
- Security isolation or privilege
- A resource or guarantee that is not enforced
- Performance degradation, with the mechanism that causes it
- A failed install, start, restart or upgrade
- Compatibility breakage for an existing consumer
- Status or configuration acceptance that misrepresents the real state
- A failure detected too late to recover cleanly
- An operator who cannot diagnose or correct the failure

## Ground it

The consequence has to follow from the diff, the repository, the tests, the
docs, or an established contract. Before claiming it, check the things that
decide whether it is true:

- the actual default value;
- whether anything downstream enforces the value at all;
- what event makes the faulty state start mattering;
- whether the affected thing fails, is degraded, or merely gets a different
  number;
- whether any interface misrepresents the effective state;
- whether the affected path is supported;
- how far it reaches: one caller, one build, or everything downstream;
- whether it happens immediately or only under a specific condition.

Check these before you write, not after. A claim dies the moment you read the
code it rests on and find it already handles the case.

A precise conditional is not hedging. It names the condition and the result.
"This may impact users" names neither.

Never invent a consequence to hold up a severity. These say nothing, and a
finding that leans on one is not finished: *this may impact users; this could
affect stability; this may cause performance issues; this could have security
implications; this behaviour may be problematic; this is important because;
this highlights a risk; there may be an issue.*

## Severity follows the consequence

Severity comes from what happens if the code ships. The amount of code
involved, the fact that a value is ignored, and the fact that two paths differ
are not consequences and do not set severity on their own.

A finding at the top of your skill's taxonomy has to state a consequence that
carries it. If you cannot state one, use the lower rating. Do not invent an
impact to keep the higher one, and do not introduce a severity name your skill
does not already define.

## Keep it to a sentence

The consequence is one sentence, occasionally two, worked into the
explanation. It is not a section. No `Impact:` heading, no `Why this matters:`
heading, and no severity justification repeated across findings in the same
words. A finding that grew a paragraph to justify itself is usually one whose
consequence has not been found yet.

## When you cannot establish it

Do not raise the severity to compensate, and do not ask for a change. Each
skill says where an unprovable observation goes. `pr-review` has a
*Could not determine importance* section, and items there are exempt from all
of the above, because recording that the consequence could not be established
is the entire point of them. `test-coverage-review` has no such section: a gap
with no reachable failure is not a gap.

## The check a finding has to pass

A finding passes when every answer is yes:

1. Does it explain the actual runtime behaviour, not just the shape of the code?
2. Does it say who or what is affected?
3. Does it say what fails, degrades, becomes exposed, or becomes misleading?
4. Does that consequence justify the severity assigned to it?
5. Is the impact grounded in evidence from the repository?
6. Is the impact specific to this finding rather than language that would fit
   any finding?
7. For a test gap, does the proposed check assert the behaviour that protects
   against that consequence?

Question 6 is the one a keyword check cannot answer. A sentence containing
"user", "security" or "performance" satisfies nothing by itself. The test is
whether the sentence would still read as true if it were moved onto a different
finding. If it would, it is generic, and the finding does not pass.
