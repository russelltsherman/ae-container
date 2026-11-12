---
status: living
---

<!-- Front matter: `status` is always `living`. -->

# Architecture: <name>

## Overview

<!-- How the system works end to end, in a few paragraphs. A diagram may be
     embedded. Stay at the level of components and how they connect. -->

Technology:

<!-- The main technology the system is built with: languages, platforms,
     frameworks, data stores. Cite the decision behind each choice. -->

- <technology> (D<n>)

## Patterns

<!-- The well-known architecture patterns the system uses, each naming its
     `pattern-*` skill, where it is used, and the decision that adopted it.
     Every pattern here is listed in that decision record's `patterns:`
     front matter, and every pattern a decision record lists appears here.
     Write "None." when the system uses none. -->

- pattern-<name>: <where it is used>. (D<n>)

## Components

<!-- One heading per component. Keep each one high level: what it is
     responsible for, what it serves, the decisions behind it, and the
     contracts it provides. How it is built belongs in its LLD. -->

### M1 <name>

<!-- Responsibility in one or two sentences. -->

Serves: SC<n>, SQT<n>. Decisions: D<n>.

Contracts:

<!-- Each contract this component provides to another component: an API, an
     event, a schema or a file format. -->

- I1. <name>: <kind>, used by M<n>. Defined in <where>.

## Data ownership

<!-- Each piece of data has exactly one owner, the only component that may
     write it. -->

| Data | Owner | Readers |
| --- | --- | --- |
| <data> | M<n> | M<n> |

## Open questions

<!-- Questions the operator has not answered yet. -->

- <question>
