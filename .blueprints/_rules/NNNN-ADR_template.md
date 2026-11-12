---
status: "proposed"
date: YYYY-MM-DD
supersedes: D<n>
components: [M<n>, M<n>]
contracts: [I<n>]
patterns: [pattern-<name>]
decision-makers: [list everyone involved in the decision]
consulted: [list everyone whose opinions are sought, two-way communication]
informed: [list everyone kept up-to-date, one-way communication]
---

<!-- status: one of proposed | accepted | rejected | deprecated | superseded by D<n>.
     Once accepted, the status line is the only thing that may change.
     supersedes: the decision this record replaces; delete the line if none.
     components, contracts: the components and contracts this decision
     affects; delete a line if none.
     patterns: the `pattern-*` skills naming the architecture patterns the
     chosen option adopts; delete the line if none. Every pattern listed here
     also appears in the Patterns section of ARCHITECTURE.md, citing this
     decision. -->

# NNNN. <short title naming the problem and the proposed solution>

## Context and Problem Statement

<2–3 sentences describing the problem and its context. Optionally phrase the
problem as a question. Link related ADRs, tickets, or docs.>

## Decision Drivers

<!-- The criteria the options are judged against. A driver may cite a system
     constraint or quality target by ID, or be free text for a force that is
     not recorded as one. Every quality target this decision affects must be
     listed as a driver. -->

- SQT<n>. <quality target>
- SC<n>. <system constraint>
- <driver — a force, concern, or requirement>

## Considered Options

<!-- At least two real options. One must be marked as the simplest workable
     option: the least complex option that meets the constraints and targets.
     It may also be the proposed option. An option that applies a well-known
     architecture pattern names its `pattern-*` skill; consider the simpler
     alternative that pattern names as an option too. Never propose a
     pattern only because it is well known. -->

- <option 1> (simplest workable)
- <option 2> (pattern-<name>)

## Decision Outcome

Chosen option: "<option N>", because <justification tied back to the drivers>.

## Consequences

- Good, because <positive consequence>
- Bad, because <negative consequence / accepted trade-off>

## Pros and Cons of the Options

<!-- One section per considered option. Estimate the option against every
     driver: for a quality target, a rough number and whether it meets the
     target. An option that applies a pattern also lists that pattern's
     known costs and risks, from its `pattern-*` skill, as Bad arguments. -->

### <option 1>

- SQT<n>: <rough estimate>, <meets / misses> the target
- SC<n>: <fits / conflicts>, because <reason>
- Good, because <argument>
- Bad, because <argument>

### <option 2> (pattern-<name>)

- SQT<n>: <rough estimate>, <meets / misses> the target
- Good, because <argument>
- Bad, because <argument>
- Bad, because <a known cost of the pattern>

<!--
Optional MADR 4.0 sections (add when useful, in this order):
  ## Confirmation              — how compliance is verified; goes before
                                 Pros and Cons of the Options
  ## More Information           — links, related ADRs, confidence, revisit
                                 triggers; goes last
-->
