# Small open-weight models (≤ 8B) for on-device tool calling on iPhone — benchmarks and cost (as of 2026-11-20)

> **Method caveat (read first).** In this research session, WebFetch could not reach outside hosts:
> `gorilla.cs.berkeley.edu` (the BFCL leaderboard), `ai.google.dev` and `arxiv.org` all failed DNS
> in the sandbox. So every number below comes from WebSearch result summaries of the cited pages. I
> could not open the full pages. Each figure is cited to the page the search attributed it to, but
> none was checked against the live BFCL table or the full PDF. Treat column alignment in tables
> (especially BFCL sub-scores) as "probably right, verify before quoting". To re-verify, allow those
> hosts in the network settings.
>
> **Benchmark-version warning.** BFCL v2, v3 and v4 overall scores cannot be compared with each
> other. v4 (current) adds agentic categories, so the same model scores much lower on v4 than on v3
> (see Qwen3-4B-Instruct-2507 below: 61.9 v3 vendor vs ~35.7 v4 leaderboard). Vendor-reported
> numbers are labelled **[vendor]**. Independent leaderboard or third-party numbers are labelled
> **[independent]** or **[third-party blog]**.

## Which small models score highest on BFCL (overall, irrelevance/abstention, multi-turn)?

### Takeaway
No single independent table covers today's small models. On each source's own numbers, the strongest
small tool-callers as of Nov 2026 are: Qwen3-4B-Thinking-2507 (BFCL v3 71.2 [vendor]); the
function-calling specialist xLAM-2-3b-fc-r (BFCL v3 overall 65.11, multi-turn 56.00, relevance 94.44
on the April 2025 leaderboard [independent]); Qwen3.5-9B (BFCL v4 66.1 [vendor], just above the 8B
cap); and the just-released LFM3-1.7B (BFCL v4 71.39 [vendor], not independently confirmed).
Irrelevance (abstention) remains weak across the board: about 57–58 % for xLAM-2, the best-documented
small specialist.

### Cited Findings

#### Comparison table (each cell sourced in the "Src" column; "n/f" = not found)

| Model id | Params (total / effective) | Licence | Context | Tool-call format | Vision | Tool-calling scores (version, date, provenance) | Src |
|---|---|---|---|---|---|---|---|
| `Qwen/Qwen3.5-0.8B` | 0.8B | Apache 2.0 | conflicting: 262K vs 32K | Qwen3.5 template; vLLM `qwen3_coder` tool parser | Yes (vision-language) | BFCL v4 25.3 [third-party listing, single source] | [rits/NYU](https://rits.shanghai.nyu.edu/ai/qwen-3-5-small-models-9b-parameters-that-beat-120b/), [Unsloth docs](https://unsloth.ai/docs/models/qwen3.5), [therundown](https://www.therundown.ai/tools/qwen3-5-small) |
| `Qwen/Qwen3.5-2B` | 2B | Apache 2.0 | as above | as above | Yes | BFCL v4 43.6 [third-party listing, single source] | same |
| `Qwen/Qwen3.5-4B` | 4B | Apache 2.0 | as above | as above | Yes | BFCL v4 50.3 [third-party listing, single source] | same |
| `Qwen/Qwen3.5-9B` (just above the cap) | 9B | Apache 2.0 | conflicting: 262K vs 128K | as above | Yes | BFCL v4 66.1, TAU2 79.1 [vendor via press]; Liquid's LFM3 table puts it at 62.83 BFCL v4 [vendor, a competitor's run] | [rits/NYU](https://rits.shanghai.nyu.edu/ai/qwen-3-5-small-models-9b-parameters-that-beat-120b/), [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/) |
| `Qwen/Qwen3-4B-Thinking-2507` | 4B | Apache 2.0 | n/f in this session | Qwen3 Hermes-style `<tool_call>` | No | BFCL v3 71.2; TAU2 Retail 53.5 / Airline 58.0 / Telecom 27.2 [vendor] | [HF card](https://huggingface.co/Qwen/Qwen3-4B-Thinking-2507) |
| `Qwen/Qwen3-4B-Instruct-2507` | 4B | Apache 2.0 | n/f | same | No | BFCL v3 61.9 [vendor, via secondary copy of the card]; TAU2 Retail 40.4 / Airline 24.0 / Telecom 13.2 [vendor]; **BFCL v4 overall ~35.7 (FC), multi-turn 22.12, rank ~60 [independent leaderboard via aggregator]** | [HF card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), [benchmarklist v4](https://benchmarklist.com/benchmarks/bfcl_v4/) |
| `Qwen/Qwen3-4B` (original, Apr 2025) | 4B | Apache 2.0 | n/f | same | No | BFCL v3 65.9 (thinking) [vendor]; BFCL overall 62.0, multi-turn 35.3 [academic poster, ACM 2026] | [HF 2507 card](https://huggingface.co/Qwen/Qwen3-4B-Thinking-2507), [TinyLLM poster](https://dl.acm.org/doi/10.1145/3801487.3805608) |
| `Qwen/Qwen3-0.6B`, `Qwen3-1.7B` | 0.6B / 1.7B | Apache 2.0 | n/f | same | No | Per-size BFCL v3 values are in the Qwen3 tech report but the search snippet did not label the columns. In one paper's simple/irrelevance subset, Qwen3-0.6B (no-think) scored 62.3 % at FP16 (see quantization section) | [Qwen3 tech report](https://arxiv.org/pdf/2505.09388), [arXiv 2608.22472](https://arxiv.org/pdf/2608.22472) |
| `Salesforce/xLAM-2-3b-fc-r` | 3B (Qwen2.5 base) | CC-BY-NC-4.0 (training knowledge, not verified this session) | n/f | xLAM JSON tool calls | No | **BFCL v3 (snapshot 2025-04-03): overall 65.11, rank 14; multi-turn 56.00; relevance 94.44 (ties best); irrelevance 57.94** [independent leaderboard as printed in the APIGen-MT paper] | [APIGen-MT arXiv 2504.03601](https://arxiv.org/pdf/2504.03601) |
| `Salesforce/xLAM-2-1b-fc-r` | 1B | as above | n/f | same | No | Same snapshot: one search returned "43.12 / relevance 88.89 / irrelevance 56.87". That summary also misread xLAM-2-3b's multi-turn 56.00 as its "overall", so **43.12 is probably the 1B's multi-turn score, not its overall. Verify.** | [APIGen-MT](https://arxiv.org/pdf/2504.03601) |
| xLAM-2-3b (independent re-run) | 3B | — | — | — | — | BFCL overall ≈65.7 %, multi-turn 55.6 % [academic poster] | [TinyLLM poster](https://dl.acm.org/doi/10.1145/3801487.3805608) |
| `MadeAgents/Hammer2.1-3b` (also 0.5B/1.5B/7B) | 3B (Qwen2.5-Coder base) | n/f | n/f | Hammer JSON | No | Added to BFCL Dec 2024. The model card claims "enhanced irrelevant information inspection", but no figure was retrievable. SOTA2 mirror shows 81.4 in an unlabelled non-live column vs Qwen3-4B 75.3 (metric unclear) | [HF card](https://huggingface.co/MadeAgents/Hammer2.1-3b), [SOTA2](https://www.sota2.com/research/sota/function-calling-on-berkeley-function-call-leaderboard-bfcl-non-live-out-of-domain) |
| `LiquidAI/LFM3-1.7B` (released 2026-10-27) | 1.7B | Liquid LFM open licence (revenue-capped; see gap) | 256K | **XML tool calls (changed from LFM2's format)** | Text model; LFM3-VL sibling | **BFCL v4 71.39; ToolSandbox 80.36 [vendor]** (greedy, ≤32,768 output tokens). An independent blogger got 9/10 tool calls right on an M4 (tiny sample) | [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/), [HF card](https://huggingface.co/LiquidAI/LFM3-1.7B), [note.com](https://note.com/hacklog_stealth/n/nf4458ebcdfa1?hl=en) |
| `LiquidAI/LFM2.5-2.6B` | 2.6B | Liquid LFM licence | n/f | Pythonic calls | — | BFCL v4 55.89 [vendor, from LFM3 table] | [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/) |
| `LiquidAI/LFM2.5-1.2B-Instruct` / `-Thinking` | 1.2B | Liquid LFM licence | n/f | Pythonic function calls | — | BFCL v3 49.12 (Instruct) [third-party summary of vendor]; 49 → 57 BFCL v3 for Thinking [third-party blog] | [HF card](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct), [Liquid blog](https://www.liquid.ai/blog/introducing-lfm2-5-the-next-generation-of-on-device-ai), [Medium](https://medium.com/@meshuggah22/lfm2-5-1-2b-thinking-liquid-ais-reasoning-model-that-fits-in-your-pocket-12d5e8298cec) |
| `ibm-granite/granite-4.0-1b` / `-h-1b` | 1B | Apache 2.0 | n/f | Granite template | No | BFCL v3 54.82 (1B dense) / 50.21 (H-1B) [vendor]. IBM's comparison: Qwen3 52.2, Gemma 3 16.3 (sizes as IBM chose them) | [HF H-350M card](https://huggingface.co/ibm-granite/granite-4.0-h-350m), [VentureBeat](https://venturebeat.com/ai/ibms-open-source-granite-4-0-nano-ai-models-are-small-enough-to-run-locally) |
| `ibm-granite/granite-4.0-350m` / `-h-350m` | 350M | Apache 2.0 | n/f | same | No | BFCL v3 39.32 / 43.32 [vendor] | [HF card](https://huggingface.co/ibm-granite/granite-4.0-h-350m) |
| `ibm-granite/granite-4.0-micro` (3B) / `-h-tiny` (7B total, ~1B active MoE) | 3B / 7B | Apache 2.0 | n/f | same | No | Tiny card's BFCL v3 row: 59.98 / 57.56 / 57.65 / 64.69. **The first value is probably Micro (dense 3B); the column mapping is uncertain** [vendor] | [HF H-Tiny card](https://huggingface.co/ibm-granite/granite-4.0-h-tiny) |
| `HuggingFaceTB/SmolLM3-3B` | 3B | Apache 2.0 | n/f | `xml_tools` (JSON in XML) or `python_tools` | No | "BFCL" 92.3 (no think) / 88.8 (think) [vendor]. The very high figure suggests a BFCL subset, not the overall. A third-party local-agent benchmark scored it 0.71–0.74 | [HF card](https://huggingface.co/HuggingFaceTB/SmolLM3-3B), [tool-calling-benchmark](https://github.com/MikeVeerman/tool-calling-benchmark) |
| `meta-llama/Llama-3.2-3B-Instruct` | 3.2B | Llama 3.2 Community | 128K (training knowledge) | Llama 3.x JSON / pythonic | No (text) | BFCL v2 67.0 [vendor, via secondary]; Microsoft's table: 78.6 "BFCL"; **BFCL v3 (FC) 45.86 % [independent via aggregator]** | [Medium](https://medium.com/@tsunhanchiang/llama-3-2-metas-blueprint-for-consumer-ai-77d184bce6de), [NVIDIA NIM Phi-4-mini card](https://docs.api.nvidia.com/nim/reference/microsoft-phi-4-mini-instruct), [benchmarklist v3](https://benchmarklist.com/benchmarks/bfcl_v3/) |
| `meta-llama/Llama-3.2-1B-Instruct` | 1.2B | Llama 3.2 Community | 128K | same | No | BFCL v2 25.7 [vendor via secondary]; BFCL v3 (FC) 21.95 % [independent via aggregator] | same |
| `microsoft/Phi-4-mini-instruct` | 3.8B | MIT (training knowledge) | 128K (training knowledge) | Phi-4 `<\|tool\|>` JSON | No | "BFCL" 70.3 [vendor]; **BFCL v3 (FC) 28.16 % [independent via aggregator]** | [NVIDIA NIM card](https://docs.api.nvidia.com/nim/reference/microsoft-phi-4-mini-instruct), [benchmarklist v3](https://benchmarklist.com/benchmarks/bfcl_v3/) |
| `google/gemma-4-E4B-it` (released 2026-04-02) | 8B total incl. PLE / 4.5B effective | Apache 2.0 | 128K | Native function calling (Gemma 4 template) | Yes: image + video; audio (ASR / speech translation) | Tau2 avg 42.2 [vendor]; BFCL v4 48.25 [third-party blog] | [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4), [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/), [distillabs](https://www.distillabs.ai/learn/qwen-vs-llama-vs-gemma-for-tool-calling/) |
| `google/gemma-4-E2B-it` | 5.1B total / 2.3B effective | Apache 2.0 | 128K | same | Yes (image, video, audio) | Tau2 avg 24.5 [vendor] | [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4) |
| `google/gemma-3n-E4B-it` / `E2B-it` (Jun–Jul 2025) | 8B / ~4B effective; 5B / 1.91B effective | Gemma licence | 32K | No tool-calling figure or format found | Yes (image, audio, video) | none found | [Gemma 3n overview](https://ai.google.dev/gemma/docs/3n), [dev guide](https://developers.googleblog.com/en/introducing-gemma-3n-developer-guide/) |
| `google/functiongemma-270m-it` | 270M | Gemma licence | n/f | FunctionGemma special tokens | No | Mobile Actions eval: 58 % base → 85 % after fine-tuning [vendor]. Google says it is specialised for 7 mobile functions and "may not generalize". Independent paper: base 29.3 % / Google Mobile-Actions variant 17.2 % / their fine-tune 76.5 % on MobileActionsExtended | [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/functiongemma/), [HF card](https://huggingface.co/google/functiongemma-270m-it), [arXiv 2609.25373](https://arxiv.org/abs/2609.25373) |
| Apple on-device Foundation Model (~3B; "AFM 3 Core" naming unconfirmed) | ~3B, 2-bit QAT | Proprietary (not open-weight) | 4,096 tokens (third-party write-up) | Swift `Tool` protocol in the Foundation Models framework | Yes (image input per 2025 report, training knowledge) | **No published tool-calling score found.** MMLU 67.85 [vendor]; Apple says it beats Qwen2.5-3B / Gemma-3-4B and trails Qwen3-4B | [Apple tech report 2025](https://arxiv.org/pdf/2507.13575), [GitHub write-up](https://github.com/Gunnarguy/OpenIntelligence/blob/main/Docs/Engineering/APPLE_FM_TECH_REPORT_2025.md), [Wikipedia](https://en.wikipedia.org/wiki/Apple_Intelligence) |

#### Other cited points
- TinyLLM (ACM poster, 2026; arXiv 2511.22138) evaluated models with ≤ 4B parameters on BFCL: xLAM-2-3b ≈ 65.7 % overall / 55.6 % multi-turn, Qwen3-4B 62.0 % / 35.3 %, TinyLlama-1.1B 19.7 % / 0 %. It concludes that sub-3B models can handle tool calling but ultra-compact models fail at it — [ACM poster](https://dl.acm.org/doi/10.1145/3801487.3805608), [arXiv 2511.22138](https://arxiv.org/abs/2511.22138)
- Liquid's LFM3 launch claims LFM3-1.7B (71.39 BFCL v4) beats LFM2.5-2.6B (55.89) and Qwen3.5-9B (62.83, Liquid's run). Liquid positions it for tool calling and structured output, not complex multi-step reasoning — [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/), [MindStudio test](https://www.mindstudio.ai/blog/liquid-ai-lfm3-1-7b-local-agent-model)
- Vendor and independent rankings disagree sharply. Microsoft's own table puts Phi-4-mini at 70.3 and Llama-3.2-3B at 78.6 "BFCL". An independent BFCL v3 aggregation gives 28.16 % and 45.86 % — [NVIDIA NIM card](https://docs.api.nvidia.com/nim/reference/microsoft-phi-4-mini-instruct), [benchmarklist v3](https://benchmarklist.com/benchmarks/bfcl_v3/)
- Qwen3-4B-Thinking-2507 beats Qwen3-4B-Instruct-2507 on BFCL v3 (71.2 vs 61.9) and TAU2-Retail (53.5 vs 40.4) [vendor] — [HF Thinking card](https://huggingface.co/Qwen/Qwen3-4B-Thinking-2507), [HF Instruct card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)

### Inferences
- **Best ≤ 4B candidates to test first:** Qwen3-4B-Instruct/Thinking-2507 (general model, strong across sources), xLAM-2-3b-fc-r (best independently documented multi-turn score and relevance among ≤ 3B models, but its licence appears non-commercial), LFM3-1.7B (newest, highest vendor BFCL v4 per parameter, unverified), and Gemma 4 E2B/E4B as the only candidates here that combine native tool calling with vision and audio.
- Irrelevance (correctly *not* calling a tool) is the weakest dimension in the one table with sub-scores: xLAM-2 1B/3B sit at ~57–58 %. A voice-assistant integration should therefore add its own guard (a router or confirmation step) rather than trust the model to abstain.
- Vendor "BFCL" numbers for older models (Phi-4-mini 70.3, Llama-3.2-3B 78.6, SmolLM3 92.3) look like subset or older-version figures. They should not be ranked against independent v3/v4 overall numbers.
- Ranking all candidates on the same BFCL v4 run requires the live leaderboard CSV, which was unreachable in this session.

### Gaps
- Live BFCL v4 leaderboard (current version and date, overall, multi-turn, irrelevance per small model) could not be fetched: `gorilla.cs.berkeley.edu` is blocked in this sandbox.
- No BFCL scores found for: Qwen2.5 0.5B/1.5B/3B-Instruct, Gemma 3 270M/1B (IBM's "Gemma 3 16.3" does not name the size), Gemma 3n, SmolLM2, Ministral 3B (only Ministral-8B appears, in HammerBench), Hammer2.1 (numbers present on the leaderboard but not retrieved), LFM2-1.2B-Tool, Granite 3.x.
- Qwen3-0.6B/1.7B/4B per-size BFCL v3 values in the Qwen3 tech report: the snippet's columns were unlabelled.
- Liquid licence terms for LFM2.5/LFM3 (revenue threshold) were not confirmed this session. Same for xLAM-2 licence and context lengths marked "n/f".
- Apple Foundation Model: no tool-calling benchmark published. The 2026 "AFM 3 Core" rename comes only from a truncated Wikipedia snippet.

## Which models are fine-tuned for edge function calling, and how do they compare to general instruct models of the same size?

### Takeaway
Purpose-built tool callers are xLAM-2 (1B/3B), Hammer2.1 (0.5–7B), FunctionGemma (270M), and Liquid's LFM2.5/LFM3, which are built for agents. At 3B, xLAM-2-3b-fc-r beats the general Qwen3-4B on multi-turn by a wide margin in an independent re-run (55.6 % vs 35.3 %) and slightly on overall (~65.7 vs 62.0). FunctionGemma is only good after task-specific fine-tuning on a narrow function set. The newest general models (Qwen3-4B-2507 Thinking, Qwen3.5) have largely closed the single-turn gap.

### Cited Findings
- xLAM-2-3b ≈ 65.7 % overall / 55.6 % multi-turn vs Qwen3-4B 62.0 % / 35.3 % in the same harness — [TinyLLM ACM poster](https://dl.acm.org/doi/10.1145/3801487.3805608)
- xLAM-2-3b-fc-r ranked 14th overall (65.11) on BFCL v3 (2025-04-03 snapshot), with relevance 94.44, which "match[es] the best score in this category" — [APIGen-MT](https://arxiv.org/pdf/2504.03601)
- FunctionGemma 270M: 58 % → 85 % on Mobile Actions after fine-tuning [vendor]. Google states it is specialised for 7 mobile functions and may not generalise — [Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/functiongemma/), [HF card](https://huggingface.co/google/functiongemma-270m-it)
- An independent study (arXiv 2609.25373, Sept 2026) found Google's Mobile-Actions FunctionGemma dropped to 17.2 % on an extended mobile-action set (base 29.3 %). Their broader fine-tune reached 76.5 %, and 82.3 % on Google's set vs the specialist's 90.3 %. In short, narrow fine-tunes do not transfer — [arXiv 2609.25373](https://arxiv.org/abs/2609.25373)
- Hammer2.1 claims "enhanced irrelevant information inspection"; HammerBench (arXiv 2412.16516) is a mobile-assistant function-calling benchmark from the same group — [HF Hammer2.1-3b](https://huggingface.co/MadeAgents/Hammer2.1-3b), [HammerBench](https://arxiv.org/html/2412.16516v2)
- Granite-4.0-1B (general model, tool-trained) is claimed best in its size class on BFCL v3 (54.8 vs Qwen3 52.2) [vendor] — [VentureBeat](https://venturebeat.com/ai/ibms-open-source-granite-4-0-nano-ai-models-are-small-enough-to-run-locally), [HF blog](https://huggingface.co/blog/ibm-granite/granite-4-nano)
- LFM3-1.7B is positioned "for tool calling and structured output, not agentic coding or complex multi-step reasoning" [vendor] — [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/)
- A 2026 paper ("Small Reasoning Models are Instruction Followers in Function Calling") reports reasoning-mode small models are both more accurate and more robust: Qwen3-4B (Think) scores 94.1 % FP16 on its subset — [arXiv 2608.22472](https://arxiv.org/pdf/2608.22472)
- A per-call-site study of a deployed home-automation agent argues that not every call needs a frontier model and evaluates small models per call type (details not retrieved) — [arXiv 2610.09021](https://arxiv.org/pdf/2610.09021)

### Inferences
- For a fixed, small tool set (like a glasses assistant's dozen or so intents), a fine-tuned tiny model (FunctionGemma-style, or LoRA on Qwen3/LFM) can beat general models. It will be brittle to new tools, though, so the tool list must be frozen at training time.
- Thinking or reasoning modes help accuracy and quantization robustness but cost latency (more output tokens), which matters on a phone. One quantization paper notes "token inflation" in low-bit reasoning models — [arXiv 2606.25519](https://arxiv.org/pdf/2606.25519)

### Gaps
- No same-harness comparison of Hammer2.1-1.5B/3B vs Qwen3-1.7B/4B retrieved.
- No independent BFCL run of LFM3 yet (released 3½ weeks before this note).

## What does 4-bit quantization (Q4_K_M) do to tool-calling accuracy?

### Takeaway
Evidence is thin but consistent. Plain instruct models at ≤ 1B can collapse at 4-bit (Qwen3-0.6B no-think 62.3 % → 16.8 %; Gemma-3-1B 23.9 % → 8.7 %). Reasoning-mode 4B models barely move (Qwen3-4B Think 94.1 % → 93.5 % at Q4_K_M). Model family matters more than size.

### Cited Findings
- Q4_K_M vs FP16 on a function-calling subset: Gemma-3-1B 23.9 % → 8.7 %; Qwen3-0.6B (no-think) 62.3 % → 16.8 %; Qwen3-4B (Think) 94.1 % → 93.5 %. The authors attribute the robustness to the reasoning trace — [arXiv 2608.22472](https://arxiv.org/pdf/2608.22472) (exact BFCL categories not verified)
- An independent BFCL v4 subset run (simple/multiple + irrelevance, n=200 × 3 seeds, greedy, Q4_K_M vs fp16, 4 GB laptop GPU) found Qwen3-0.6B kept schema validity at Q4_K_M but lost argument correctness. Llama-3.2-1B collapsed, worst on parallel and ToolACE-style items. Conclusion: "model family predicts robustness better than parameter count" [single-author blog] — [DEV Community](https://dev.to/happynood/does-quantization-break-tool-calling-i-measured-it-on-a-4gb-laptop-gpu-bfcl-3-seeds-bootstrap-185l)
- General quantization studies: losses are larger in smaller models and at 4-bit vs 8-bit — [arXiv 2505.20276](https://arxiv.org/pdf/2505.20276). Q4_K_M is the recommended default 4-bit GGUF for small models — [Kaitchup](https://kaitchup.substack.com/p/choosing-a-gguf-model-k-quants-i)
- Low-bit reasoning models emit more tokens ("token inflation"), a hidden latency cost — [arXiv 2606.25519](https://arxiv.org/pdf/2606.25519)
- Sustained 4-bit MLX throughput can fall sharply under thermal load (see next section), which is a runtime rather than accuracy effect — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)

### Inferences
- Below ~1.5B, prefer 6- or 8-bit, or a QAT/vendor-quantised build (Gemma QAT, Liquid's own Q4 builds, Apple's 2-bit QAT), over naive Q4. At 3–4B, Q4_K_M or MLX 4-bit looks acceptable, especially with thinking on.
- Re-run a small BFCL subset (including irrelevance) on the exact quantised artifact before shipping. Published FP16 scores do not carry over to small models.

### Gaps
- No published quantization-vs-tool-accuracy numbers for Gemma 4, LFM2.5/LFM3, xLAM-2, Qwen3.5 or Granite 4.0.
- No MLX-4bit (vs GGUF Q4_K_M) tool-accuracy comparison found.

## What size, RAM and speed figures exist on iPhone (A17 Pro / A18 / A19) or M-series?

### Takeaway
On iPhone 17 Pro (A19 Pro), 1B-class 4-bit models decode at ~55–70 tok/s. Gemma 4 E2B gets ~49–61 tok/s warm, but MLX 4-bit can fall to ~25 tok/s after 10 minutes of sustained load. 3B models run at ~24–30 tok/s on an A19 iPhone Air. 4B models are borderline: one developer could not fit Qwen3-4B or Llama-3.2-3B in their iPhone 17 Pro app. Peak memory at 4K context ranges from 0.4 GB (smallest) to 6.9 GB (9B).

### Cited Findings
- **iPhone 17 Pro, Gemma 4 E2B:** LiteRT-LM 61.1 tok/s, MLX 49.1 tok/s (warm). MLX 4-bit PTQ fell 45.7 → 25.1 tok/s over a 10-minute sustained test — [apple-silicon-llm-bench (GitHub)](https://github.com/john-rocky/apple-silicon-llm-bench)
- **iPhone 17 Pro:** Qwen3 0.6B, LFM2.5 (4-bit) and Llama 3.2 1B cluster at 58–70 tok/s for short prompts, slowing as prompts grow. Qwen3 4B and Llama 3.2 3B "couldn't fit" and were excluded (app-specific memory limit) — [rickytakkar.com](https://rickytakkar.com/blog_russet_mlx_benchmark.html)
- **iPhone 17 Pro:** Qwen3.5-2B fastest on MLX at 61 tok/s in a four-runtime comparison (MLX / llama.cpp / LiteRT-LM / Core ML) — [DEV Community](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42)
- **iPhone Air (A19):** Llama 3.2 3B 27.2 tok/s on llama.cpp (no throttling). MLX 24.3 and 30.0 tok/s, both runs throttled — [search summary of iPhone benchmark page](https://ananasdda.github.io/pocket-ai-lab/benchmarks/) (page not opened; aggregator estimates on similar pages, e.g. iPhone 16 Pro ~12–18 tok/s for 3B, are unsourced)
- **LFM2.5-1.2B 4-bit:** 70 tok/s on iPhone and 124 tok/s on iPad (community benchmark, iPhone 17 Pro). Artificial Analysis × Liquid cite 55 output tok/s on iPhone 17 Pro (model not named in snippet). Vendor: 82 tok/s decode on Snapdragon Gen4 NPU (Android) — [Liquid shoutouts](https://www.liquid.ai/shoutouts), [AlphaSignal](https://alphasignal.ai/news/liquid-ai-s-lfm2-5-beats-bigger-rivals-in-real-on-device-phone-benchmarks), [HF card](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct)
- **Artificial Analysis mobile benchmark (with Liquid AI):** 41 quantised builds tested, 33 ran on iPhone 17 Pro. Peak memory at 4K context ranges from 0.4 GB to 6.9 GB (Qwen3.5-9B, Ornith-1.0-9B). "Small" means fits in 8 GB including KV cache at 8K — [Artificial Analysis](https://artificialanalysis.ai/articles/mobile-phone-intelligence-inference), [AA mobile phones](https://artificialanalysis.ai/hardware-inference-stack/mobile-phones)
- **LFM3-1.7B:** ~1 GB at 4-bit [vendor]. Decodes 1.8–2.8× faster than the next model Liquid tested (llama.cpp Q4_0). 73 tok/s on a 16 GB M4 Mac [independent blog] — [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/), [note.com](https://note.com/hacklog_stealth/n/nf4458ebcdfa1?hl=en)
- **Gemma 3n:** runs in as little as ~2 GB (E2B) / ~3 GB (E4B) because PLE weights live on CPU. Standard (non-PLE-cached) E2B loads > 5B params — [Google dev guide](https://developers.googleblog.com/en/introducing-gemma-3n-developer-guide/), [Gemma 3n overview](https://ai.google.dev/gemma/docs/3n)
- **Mac proxy:** Qwen3-4B decode on Apple Silicon: 159.0 (paper's own stack) / 137.3 (vllm-metal) / 128.9 (mlx-lm) / 118.2 (llama.cpp) tok/s; Mac model and quant not clear in snippet — [arXiv 2601.19139](https://arxiv.org/html/2601.19139v1)
- **CPU baseline (unspecified CPU, unquantised):** Qwen2.5-1.5B 7,960 MiB, 30.8 s mean latency; Qwen2.5-0.5B 3,637 MiB, 10.6 s — [arXiv 2609.07370](https://arxiv.org/abs/2609.07370)

### Inferences
- **Approximate 4-bit weight sizes (computed by me as ≈ params × ~0.55–0.6 bytes for Q4_K_M including scales; not sourced):** 0.27B ≈ 0.2 GB; 0.6B ≈ 0.4 GB; 1.2B ≈ 0.7 GB; 1.7B ≈ 1.0 GB (matches Liquid's ~1 GB LFM3 claim); 2B ≈ 1.2 GB; 3B ≈ 1.8–2.0 GB; 3.8–4B ≈ 2.3–2.5 GB; Gemma 4 E2B (5.1B total) ≈ 3 GB file but ~1.3 GB "hot" if PLE is streamed; E4B (8B total) ≈ 4.5–5 GB file / ~2.6 GB hot. KV cache and the vision/audio encoders come on top.
- iOS's default per-app memory limit (typically about half of device RAM unless the `increased-memory-limit` entitlement is granted; training knowledge) is why 3–4B models "don't fit" in some apps on 8 GB phones. Budget ≤ ~3 GB resident for the model in an app that also runs camera/audio.
- Thermal throttling (~45 % drop over 10 minutes for Gemma 4 E2B on MLX) matters more than peak tok/s for an always-on assistant. Short, infrequent tool-routing calls suit phones better than long generations.

### Gaps
- No iPhone tok/s found for Qwen3-4B, Phi-4-mini, Gemma 4 E4B, Gemma 3n, xLAM-2 or Granite on A17 Pro / A18. Most published numbers are iPhone 17 Pro (A19 Pro).
- Prefill (time-to-first-token) figures for long tool schemas on iPhone were not retrieved. Large tool lists in the system prompt make prefill the main latency cost.

## Which have MLX (mlx-community) and GGUF builds readily available?

### Takeaway
Every major general family (Qwen3/3.5, Gemma 3n/4, Llama 3.2, Phi-4-mini, SmolLM3, Granite 4.0, LFM2.5/LFM3) has GGUF and MLX builds. Liquid ships its own GGUF/MLX/ONNX. Unsloth publishes GGUFs for Qwen3.5 and LFM2.5. Google's Gemma 3n/4 also ship LiteRT-LM builds, which were the fastest runtime for Gemma 4 E2B on iPhone 17 Pro.

### Cited Findings
- LFM3 ships GGUF, MLX, ONNX, FP8 and NVFP4 checkpoints — [MarkTechPost](https://www.marktechpost.com/2026/10/27/liquid-ai-lfm3-open-weight-2b-multimodal-models/)
- Unsloth GGUFs for Qwen3.5 0.8B/2B/4B/9B ("run 0.8B, 2B and 4B on your phone") — [Unsloth on X](https://x.com/UnslothAI/status/2028463220063871426?lang=en), [unsloth/Qwen3.5-0.8B-GGUF](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF)
- Unsloth guide and GGUFs for LFM2.5 — [Unsloth LFM2.5](https://unsloth.ai/docs/models/tutorials/lfm2.5)
- Unsloth GGUF for Qwen3-4B-Instruct-2507 (mirror) — [gitcode mirror](https://gitcode.com/hf_mirrors/unsloth/Qwen3-4B-Instruct-2507-GGUF/blob/master/README.md)
- Gemma 3n LiteRT-LM build on HF — [google/gemma-3n-E2B-it-litert-lm](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/blob/refs%2Fpr%2F2/README.md). FunctionGemma Mobile Actions LiteRT build — [litert-community](https://huggingface.co/litert-community/FunctionGemma_270M_Mobile_Actions)
- MLX, llama.cpp, LiteRT-LM and Core ML builds of Gemma 4 E2B, plus hybrid Mamba-2 models (Granite-4.0-H, Nemotron-3 Nano, Falcon-H1), benchmarked on iPhone 17 Pro — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)
- MLX + llama.cpp tool-calling benchmark harness for local models on Apple Silicon (M3 Ultra) — [lintware/tool-calling-benchmark](https://github.com/lintware/tool-calling-benchmark)

### Inferences
- MLX Swift (`mlx-swift-examples` / `MLXLLM`) and llama.cpp both expose chat templates. Tool-call parsing differs by family: Qwen uses Hermes `<tool_call>` JSON; LFM2.5 uses Pythonic calls; LFM3 uses XML; SmolLM3 uses `xml_tools` / `python_tools`; FunctionGemma uses special tokens. An app should isolate per-model parsers behind one interface.

### Gaps
- I did not verify (no fetch) that specific `mlx-community/*-4bit` repos exist for xLAM-2, Hammer2.1, Granite 4.0 Nano or FunctionGemma. MLX support for hybrid Mamba (Granite-H, LFM conv layers) depends on the mlx-lm version.
