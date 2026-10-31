# Plan KK — Game Coach (a chess position read from a glance, poker odds from the cards, for practice)

**Status:** 📝 Drafted 2026-10-31. Nothing built. P0 and P1 are pure and headless; P2 needs a vision
provider; P3 is a measured accuracy gate on real glasses photos, and that result decides whether
chess-from-a-photo ships at all.
**Track:** Personal. Not Field Assist.
**Origin:** Read 2026-10-31 from `brain/ronie_brain/games.py` in
[raunakpatil/smart-glasses-ai-agent](https://github.com/raunakpatil/smart-glasses-ai-agent) (MIT, commit
`bd64610`): a vision model turns a glasses photo into a chess position (FEN), Lichess's cloud
evaluation gives the best move, and a Monte Carlo simulation gives Texas Hold'em equity and pot odds.
We take the idea and the pure poker arithmetic. We do not take the chess fallback: when the cloud has
no evaluation, that project picks a move by a one-move greedy score (captures, centre, checks), which
is too weak to speak as "the best move".
**Related:** [Structured Vision Assessment](structured-vision-assessment.md) (the forced-schema
vision call and its deterministic backstop), Plan [C](C-live-coach-tool.md) (Live Coach, the periodic
frame loop this plan deliberately doesn't use), [Study Mode](study-mode.md) (the practice framing),
Plan [CP](CP-outbound-frame-privacy.md) (what a frame may carry out), `NetworkRouteRegistry`.

---

## Why

"What's the best move here?" and "what are my odds with ace-king suited?" are natural questions to
ask glasses, and nothing in the app answers them well today. A general model asked about a chess
photo will make up a confident move: models are poor at reading boards and worse at choosing moves.
Poker equity is arithmetic, and a model guesses arithmetic. Both need a deterministic engine behind
the model, with the model only reading the scene and explaining the answer.

## Outcomes

- **Chess, from a glance or by voice.** "Look at this board, I'm white" → the position is read,
  said back for a yes/no, then "Best move: knight from g1 to f3." After that, "I played e4, they
  played c5" keeps the position up to date without another photo. "Why?" explains in a sentence
  or two.
- **Poker, from spoken cards.** "Ace-king suited, flop is queen-jack-two rainbow, two opponents,
  pot 60, 20 to call" → "About N percent against two random hands. You need 25 percent to call…",
  where N is the simulated equity and the 25 percent is the pot odds (20 into a pot of 80). Reading cards off a table photo is P2, and only if the owner decides for it.
- **One position per ask, never a running loop.** This is the fair-play line (see *Decisions*): the
  tool answers the position it is shown when the wearer asks, and doesn't watch a game.
- **Honest about strength.** Each answer says where the move came from: the cloud engine's deep
  evaluation, or "my quick look", which is our own small search. It never presents the quick look as
  the best move.

## What exists (verified 2026-10-31, main at `8e8d10f`)

- No chess or poker code. `chess` appears once in the sources, in an unrelated sign-off string.
- `StructuredVisionService` runs a forced structured-output vision call against a registered
  `AssessmentSchema` (`AssessmentSchemaRegistry`, `Schemas/`), with an `analyze` seam for tests and
  `ImageQualityProbe` for frames too poor to read. This is the right engine for "photo → position".
- `LLMService.completeStructured(systemPrompt:userText:jsonSchema:…)` gives text → JSON for the
  spoken-cards parse when a pure parser can't settle it.
- `LiveCoachService` is a periodic frame loop with dedup and throttling. Its shape is what the
  fair-play decision rules out, so it isn't reused.
- `NetworkRouteRegistry` requires a declared route for any new outbound host. Lichess would be new.

## Design

**Pure core (P0, P1):**
- `ChessPosition`: FEN parse and print, piece placement, side to move, castling rights, en passant.
  `ChessMoveGenerator` produces legal moves (pins, checks, castling through check, en passant,
  promotion). It is tested by **perft** against published counts: the start position at depths 1–4
  gives 20 / 400 / 8,902 / 197,281, and the "Kiwipete" position at depths 1–3 gives 48 / 2,039 /
  97,862. Writing our own avoids a dependency, and the generator is small.
- `ChessPositionValidator`: one king each, no pawns on the back ranks, the side not to move isn't in
  check, and plausible piece counts. A photo read that fails validation is "I couldn't read the
  board", never a guess.
- `ChessPhotoCompletion`: a photo has no side to move, castling rights or en passant. The side to
  move comes from the wearer ("I'm white, my move"). Castling is allowed where king and rook stand on
  their home squares. En passant is "-", and the move counters are 0 and 1.
- `SpokenChessMove`: "knight f3", "bishop takes c6", "e4", "castle kingside", "pawn to e8, queen" →
  one legal move, "which knight?" when two pieces can make it, or nil. Piece and command words
  come from the string catalog, so other languages are added as words, not code. That project's
  Hindi words (ghoda, haathi, vazir…) are a starting list for a Hindi entry.
- `ChessMoveSpeech`: move → "knight from g1 to f3, check", via SAN from the generator, and an
  evaluation → "white is about a pawn better" or "mate in 3". No raw centipawn numbers are spoken.
- `ChessQuickSearch`: our own small alpha-beta (material plus piece-square tables, quiescence on
  captures, a time cap of about 300 ms). It is used when the cloud has no evaluation or the network
  is off, and is always labelled "my quick look".
- `PokerCards`: spoken or typed cards ("ace of spades", "AsKh", "ten-nine suited") → cards,
  rejecting duplicates. `PokerHandEvaluator` picks the best 5 of 7 cards, ranked with kickers.
  `PokerEquity` runs a Monte Carlo against N random hands with an injected seeded generator, so tests
  are exact. `PokerDecision` takes equity, pot and the amount to call, and gives pot odds and
  call/fold/raise, as that project's `PokerEngine.analyze` does, with its thresholds as a starting
  point.

**Edges:**
- **Cloud evaluation (P1).** `GET https://lichess.org/api/cloud-eval?fen=<fen>&multiPv=1`.
  It is free and needs no key. It answers only positions already in its cache, which means
  openings and popular lines. Anything else gets a 404, and we use `ChessQuickSearch` with the
  "quick look" label. The request carries **only the FEN**: no photo, no identity. It gets a new
  `NetworkRoute` (data class: position text), it is blocked in local-only modes, and it is
  disclosed in the network activity view. Timeout 2.5 s. A 429 rests the route for a minute.
  The request shape, the 404 behaviour, and whether move counters change the cache key are
  checked in P1 against the live API.
- **Board read (P2).** A new `AssessmentSchema` kind, `chessPosition`. The model returns an 8×8
  grid of piece letters, the side it believes is nearest the camera, and a per-square confidence.
  It does not return a FEN string: a grid is easier for a model to fill and for the validator to
  check. The deterministic backstop is `ChessPositionValidator`. `ImageQualityProbe` rejects blur
  first.
- **Read-back before advice.** A short confirmation before any move is given, e.g. "White to move;
  you've a queen and two rooks, they've lost a knight. Right?" Display glasses also show the board
  as an `Image`. "No, the knight's on f6" corrects one square. A position is advised on only
  after a yes or a correction.
- **`game_coach` tool.** Actions: `read_board` (`side`), `best_move`, `played` (`moves`),
  `explain`, `correct` (`square`, `piece`), `poker_odds` (`hole`, `board`, `opponents`, `pot`,
  `to_call`), `reset`. Effect class read. The tool description carries the fair-play line. The
  position lives in the tool's session state and is cleared on `reset` and at conversation reset
  (Plan EX).

## Phases (one PR each)

**P0 — Chess core (headless).** `ChessPosition`, `ChessMoveGenerator`, `ChessPositionValidator`,
`ChessPhotoCompletion`, `SpokenChessMove`, `ChessMoveSpeech`. Tests: perft at both positions, FEN
round-trips, validator rejections (two white kings, a pawn on rank 1, the side not to move in
check), completion (castling inferred from home squares), spoken moves (ambiguity asks; promotion;
"takes" without a capture is rejected), and speech (check, mate, castling, promotion).

**P1 — Answers without a camera (headless + live check).** `ChessQuickSearch` (finds mate in 1
and 2 in fixture positions within its time cap, and never returns an illegal move), the poker core
(evaluator ordering across all hand classes; equity fixtures with a seeded generator, such as AA
against one random hand at about 85% and 72 offsuit at about 35%, within a tolerance; pot odds),
the Lichess client behind its route with a fake transport, and the `game_coach` tool with
`played` / `best_move` / `explain` / `poker_odds` (spoken input only). One live check of the
cloud-eval request shape is recorded in the PR.

**P2 — Reading a board (provider-dependent).** The `chessPosition` schema, the read-back and
`correct` actions, and the HUD board image. Tests run through the structured-vision `analyze` seam
with recorded model outputs: a clean read, a mirrored board, one wrong square, and an unreadable
photo.

**P3 — Accuracy gate (owed, device + providers).** Thirty glasses photos of real boards, with ground
truth: varied light, angles, piece sets, and some from the wearer's own seat. Measure per provider
the exact-position rate and the per-square error rate, before and after one spoken correction. The
owner sets the bar (see *Decisions*). Below it, `read_board` stays off and chess works by voice
only.

## Acceptance

- No move is ever spoken for a position that failed validation or wasn't confirmed.
- Every move answer names its source, the cloud's deep evaluation or "my quick look".
- With the network off, chess and poker still answer, from the quick look and local equity.
- The Lichess route carries only a FEN and appears in network activity.
- There is no periodic loop. Each answer follows a request from the wearer.

## Decisions for Greig

1. **Fair-play line.** *Recommend:* practice, analysis and teaching only. One position per request,
   no running loop. The tool description tells the model to decline when the wearer says it is a
   rated or tournament game, or a real-money table, and the product copy says so. Electronic help
   is prohibited in rated chess and at casino tables, and covert use can't be detected, so the
   design doesn't make it easy.
2. **Poker from the camera.** *Recommend:* spoken cards only. An equity calculator for hands you
   describe is clearly a study tool. Reading a live table from glasses invites the casino and
   App Review questions for little gain.
3. **Engine.** *Recommend:* the Lichess cloud plus our own small search, labelled honestly. Stockfish
   is GPLv3 and can't be bundled into a BSL app. A permissively licensed stronger engine is welcome if
   P1 finds one worth the size.
4. **P3 bar.** For example, ≥ 80% of positions exact after at most one spoken correction, on the best
   provider. Below that, voice-only chess.

## Out of scope

Other board games: that project's "board game referee" is a hard-coded rules table, and the general
model already knows the rules. Also out: playing a full game against the app, opening books, game
import/export (PGN), and interview or exam help of any kind.
