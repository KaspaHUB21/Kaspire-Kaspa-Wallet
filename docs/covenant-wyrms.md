# Covenant Wyrms v1

This private Mainnet prototype is exposed by GothDAG at `/dragons`. The first
eight genesis serials are assigned to the configured internal test wallet; the
public cap remains 287.

## Trust model

- Kaspire prepares, reviews, signs and broadcasts every genesis or transition.
- The Wyrm is a Toccata singleton covenant output with a permanent Covenant ID.
- GothDAG never holds the owner's key and never broadcasts a Wyrm transaction.
- GothDAG recompiles the submitted state with `covenant_wyrm_inspect`, checks the
  accepted transaction and current UTXO against its local Kaspa node, and only
  then advances its official registry.
- A transition consumes the current singleton plus a newly confirmed P2PK
  action output. Its consensus DAA score is the lifecycle clock.

## Lifecycle

- Egg: indefinite; may be transferred.
- Incubation: begin, warm after 12 hours, hatch after another 12 hours.
- Living: feed once the previous 24-hour care interval has elapsed. Death is
  enforceable after 72 hours without feeding.
- Growth: 7, 21 and 69 care points plus active days.
- Crystal Sleep: pauses the remaining life-flame interval, requires at least 24
  hours before wake, and is required before transferring a living Wyrm.
- Memorial: terminal state; singleton termination is disallowed.

## Special feed

Ancient Bones, Blood Vials, Moon Dust, Teal Crystals and Bat Wings map to Bone,
Blood, Moon, Teal and Night development counters. GothDAG reserves one unlisted
artifact before wallet approval, prevents Hexchange/ritual double-spending, and
consumes it only after the local node confirms the matching Covenant successor.
The highest counter selects the adult specialization; the owner chooses when
multiple counters tie.

The source of truth is `crates/kaspa_secure_core/src/covenant_wyrm.sil`. Any
change to its state or rules changes the template hash and requires rebuilding
both Kaspire clients and GothDAG's inspector binary.
