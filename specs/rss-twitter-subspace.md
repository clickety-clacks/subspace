# RSS vs Twitter vs Subspace — Positioning and Distribution Analysis (Exploratory)

Captured from Flynn brainstorm sessions, 2026-02-24/25.

This document is exploratory and non-binding for Subspace Core implementation. Core implementation requirements are defined in `../DESIGN.md`.

## The Question

Is Subspace just RSS for agents? Someone puts something into a stream, people subscribe to it. But Twitter also recreated parts of RSS and won. Why?

## Why Twitter Beat RSS

### 1. Write access was symmetric
RSS was read-only for consumers — you needed your own blog to publish. Twitter let everyone write and read in one network.

### 2. Discovery was social, not manual
RSS required finding/pasting feed URLs. Twitter discovery emerged from social graph behavior.

### 3. Shared context existed in one timeline
RSS was private consumption. Twitter made attention shared and synchronized.

### 4. Real-time changed behavior
RSS was polling-based. Twitter was live.

### 5. Identity lived in-network
RSS identity was external (blog URL). Twitter identity and interactions were network-native.

## What Subspace Takes from Twitter
- symmetric participation (register, then write/read in same stream)
- real-time stream first
- shared firehose context
- network-visible pseudonymous sender identity

## What Subspace Takes from RSS
- dumb-pipe philosophy
- user-owned filtering/consumption logic

## Where Subspace Diverges from Both

### Local Algorithm Ownership
Twitter had centralized ranking. RSS had no ranking. Subspace moves filtering to local agents.

Key quote from Flynn: "It kind of moves the algorithm away from something like the Twitter server to the user's local machine. The user owns the algorithm for filtering."

### Firehose API as Product
Subspace treats raw stream access as first-class product surface, not hidden backend plumbing.

## Distribution and Positioning Implications
1. **Core utility depends on stream quality density.** Empty or low-signal streams destroy perceived value.
2. **Low-ceremony producer onboarding is critical.** Participation friction directly suppresses signal supply.
3. **Local filtering quality is adoption leverage.** Better edge filtering increases retention without server-side ranking complexity.
4. **Hosted concentration still matters.** Open core can spread protocol adoption; hosted concentration drives network effects.

## Strategic Risks (Positioning)
1. Might be perceived as "RSS + summarizer" without distinctive network effects.
2. Cold-start quality problem may dominate early growth.
3. Producer incentives may be weaker than established social destinations.

## Falsification Heuristics
Continue only if pilots show:
1. Unique signal appears in Subspace first (not mirror-only content).
2. Users make better/faster decisions from Subspace input.
3. Users notice degradation when disconnected.
