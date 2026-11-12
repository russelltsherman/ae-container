---
status: living
component: M<n>
decisions: [D<n>, D<n>]
targets: [SQT<n>]
policies: [policy-<name>]
---

<!-- Front matter: `status` is always `living`. `component` names the
     component in ARCHITECTURE.md that this directory designs. `decisions`
     lists every decision this design relies on, `targets` every system
     quality target it helps meet, and `policies` every `policy-*` skill
     applied to this design; delete a line if none. -->

# Spec: M<n> <name>

<!-- Turn INTENT.md into requirements and a design for the whole component,
     not the next change or roadmap phase. Edit this document as the
     component changes.

     Every design here stays inside the component. If it would add, remove
     or split a component, change a contract, move data ownership, change a
     quality target or contradict a decision, do not write it into the
     spec: flag it, name the HLD change needed and leave it for the
     operator to take to `hld`. -->

## Requirements

<!-- Testable statements of what the component must do. Each requirement
     cites the constraints and component quality targets from INTENT.md
     that it serves. Every constraint and quality target in INTENT.md is
     served by at least one requirement. -->

- R1. The component must <behavior>. Serves C<n>, QT<n>.

## Design

<!-- How the component meets its requirements, inside its own boundary.
     Keep every subsection below; write "None." under one that does not
     apply. -->

### Overview

<!-- How the component works end to end, in a few paragraphs. A diagram
     may be embedded. -->

### Technology

<!-- Languages, libraries and stores used inside the component. Cite the
     decision behind any choice the HLD made; a choice the HLD left open is
     made here, with its reason. -->

- <technology>. <reason or D<n>>.

### Structure

<!-- The modules inside the component and what each is responsible for.
     Name modules, not files: files belong in PLAN.md. -->

### Data

<!-- The data this component owns: its shape and how it is stored. Only
     data ARCHITECTURE.md lists this component as owning. -->

### Contracts

<!-- How the component provides each contract ARCHITECTURE.md lists for it,
     and how it uses the contracts it depends on. The contract itself is
     defined in the HLD; describe only how this component meets or uses
     it. -->

- I<n>. <how it is provided or used>

### Failure handling

<!-- What the component does when its inputs, dependencies or own work
     fail. -->

## Concerns

<!-- Undecided points inside the component that the operator must settle.
     For each, the options and their trade-offs; never pick one. A boundary
     crossing is never a concern.

     Once the operator settles a concern, write the answer into the
     requirements or design where it belongs and remove the concern from
     this list. Concerns have no IDs: nothing cites them. -->

<!-- Write "None." when nothing is undecided. -->

- <question>. Options: <option>, <option>.
