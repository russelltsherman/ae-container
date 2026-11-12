---
status: proposed
component: M<n>
---

<!-- Front matter: `status` is `proposed` until the work is done, then
     `completed`. `component` names the component in ARCHITECTURE.md that
     this directory designs.

     A plan covers one change and is not a living document. `lld` replaces a
     `completed` plan with the next one; it stops and asks the operator
     before replacing a `proposed` one. -->

# Plan: M<n> <name>

<!-- How to bring the code in line with SPEC.md and PROOFS.md: only the gap
     between them and the code as it is today. Read the code before
     writing; never plan against a guess of what exists. -->

## Files

<!-- Every file the work adds, edits or removes, and the requirements each
     change serves. Name real paths. Every row cites at least one
     requirement. -->

| File | Change | Requirements |
| --- | --- | --- |
| `<path>` | add / edit / remove: <what changes> | R<n>, R<n> |

## Order of work

<!-- Steps in the order they are done. Each work step cites the
     requirements it completes, and ends with the code building and those
     requirements' proofs in PROOFS.md passing. The last two steps are
     always the two below, copied as written and numbered on from the work
     steps. Closing the plan is the final unit of work: the change is not
     done until this plan says `status: completed`. -->

1. <step>. (R<n>)
2. Write the lasting lessons. Write each thing learned during this change
   that stays true after it where it belongs: a lesson about how the
   component behaves or is built goes into SPEC.md, as a requirement or in
   the design; a lesson about how to verify a requirement goes into its
   proof in PROOFS.md; a lesson that crosses the boundary rule goes to the
   operator to take to `hld`. If there are none, say so. Done when every
   lesson is written or handed to the operator.
3. Close the plan. Set this plan's front matter to `status: completed`.
   This is the final unit of work: the change is not done until this step
   is. Done when the front matter says `status: completed`.

## Risks

<!-- What could go wrong while doing the work, and what limits the damage. -->

- <risk>. Mitigated by <how>.
