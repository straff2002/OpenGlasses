# Plan NL — Canada, Patient-Linked (what it would take for the app to hold or share data tied to a patient for a Canadian clinic)

**Status:** 📝 Drafted 2026-11-27. **Parked.** It is built only if a clinic answers yes to "do you
need patient linkage in the app?" (Plan [NJ](NJ-canada-inventory-only-clinic-stock.md), open
question 3). Most of it is agreements and evidence rather than code.
**Track:** Medical Compliance mode, Canada.
**Builds on:** Plans [NJ](NJ-canada-inventory-only-clinic-stock.md) and
[NK](NK-clinic-stock-in-the-clinics-own-workbook.md); the compliance programme (Plans
[EP](EP-compliance-programme.md), [EQ](EQ-compliance-assessment.md),
[ES](ES-iso27001-isms.md), [ET](ET-iso27701-privacy.md)).

---

## Trigger

The research report of 2026-11-27 (kept outside the repo; not legal advice) found Canada asks more
than New Zealand, the US or Australia once a record is tied to a patient. This plan writes that down
before anyone promises it, so the answer to "can the app take the patient from the EMR?" comes with
its cost.

The research's verdict was **a product line, not a pilot feature**: about 6–14 weeks of engineering
and paperwork. A SOC 2 Type I at roughly USD 15–40k is likely too if a buyer or EMR partner asks.
Each province needs its own agreement.

## What changes once a patient is linked

| | What the law asks | Where |
|---|---|---|
| **The company's role** | An agent, electronic service provider, information manager or information management service provider of the clinic | ON PHIPA and O. Reg. 329/04 s.6; AB HIA s.66; SK HIPA s.18; MB PHIA s.25; NS PHIA s.28; NL PHIA s.22; PEI HIA s.42; NB PHIPAA; QC R-22.1 s.77; Yukon HIPMA s.51 |
| **A written agreement** | Mandatory almost everywhere, with set contents (for example Alberta's Regulation s.7.2, nine items) | as above; PIPEDA Principle 4.1.3 "comparable protection" by contract |
| **Storage outside the province** | Alberta: a separate written agreement before any storage or use outside Alberta (Reg s.8(4)). Quebec: a PIA before information leaves Quebec. No outright ban for private clinics elsewhere. BC's and Nova Scotia's public-body rules don't reach a private clinic. | AB, QC [confirm the Quebec sections] |
| **A foreign court order** | Disclosing under a non-Alberta order is an offence (up to $1M for a company) | AB HIA s.107(5.1) |
| **A PIA** | Alberta: submitted by the clinic to the OIPC before go-live. The company can file an information-security policy once (s.64.2) for reuse across Alberta clinics. Quebec: before transfer, and for technology projects. Federal Bill C-36 would add one if it passes. | AB s.64, s.64.2; QC; C-36 (at second reading, not law) |
| **User-activity records** | Whose record was opened, by whom, when, which part, and any onward disclosure. A Nova Scotia patient can ask for theirs, free, within 30 days. | MB Reg s.4; NS s.63; NL s.48(2); QC art. 103 (pending); ON s.10.1 (not in force) |
| **Breach** | Vendor to clinic "as soon as practicable", "without delay" or at the first reasonable opportunity. The clinic then notifies on provincial thresholds. PIPEDA requires a record of every breach for 24 months where it applies. | AB s.60.1; NS s.28(3); SK Reg s.7; QC s.77; PIPEDA s.10.1 |
| **Retention** | Saskatchewan: 10 years after last care, with a destruction log | SK |
| **Staff** | Confidentiality undertakings from the vendor's own staff | QC s.77; NL s.14(4) and s.22(5) |
| **Expectation, not law** | Canadian storage: the colleges, the CMPA and doctors' associations push for it, and Microsoft 365 provisioned in Canada gives it free | colleges, CMPA |

## Design (if built)

### 1 · Where patient-linked data may live

In order of preference:
1. **The clinic's EMR.** The patient-to-lot link already lives there, and a recall needs nothing
   else.
2. **The clinic's own Microsoft 365, provisioned in Canada** (Plan NK's route, with a different
   schema). Defensible.
3. **A Google Sheet.** Weaker. It needs a Quebec PIA and fails "kept in Canada" expectations.
4. **The company portal as built** (one Mac in New Zealand, Cloudflare decrypting in transit). **Not
   acceptable** in any province, nor in New Zealand, the US or Australia. Moving it to Canada means
   a Canadian-region instance with encrypted Canadian backups, TLS ending on the instance, an access
   log, a breach runbook and the agreements. That is 1–3 weeks to migrate, plus everything below.

### 2 · End-to-end encryption, keys on the clinic's phones

Rows tied to a patient are encrypted on the phone with a clinic key that never leaves the clinic's
devices. Keys rotate, and a seat can be revoked.

That takes Cloudflare's view down to ciphertext. It gives the US breach safe harbour, and it makes
"reasonable safeguards" defensible in New Zealand and Australia.

It does **not** remove the Canadian agreements, Alberta's prior agreement, Quebec's PIA or US
business-associate status. Ontario's regulator has held that encrypted records are still personal
information. The research found no Canadian regulator saying ciphertext held without the key falls
outside the acts [confirm]. Size: 2–4 weeks.

### 3 · Per-user identity and a per-record access log

No shared logins. A user-activity record per patient record (whose, who, when, which part, any
onward disclosure), exportable for a patient's request within 30 days. If any shared store holds
patient data, the log is kept on the server as well.

The present log stays on the phone, is capped at 1,000 entries and has no user or record field, so
it does not meet these rules. Size: 1–2 weeks, plus 3–5 days for a server log.

### 4 · Retention and destruction

Patient-linked records keep the province's period (Saskatchewan's is the longest found, 10 years),
with a destruction log. Size: 2–3 days.

## The work list

| # | Item | Size | Cost |
|---|---|---|---|
| L1 | A master information-manager and processing agreement with a schedule for each province (AB s.66, Reg s.7.2 and s.8(4); SK s.18 and Reg s.7; MB s.25; ON agent or electronic service provider terms; QC s.77; NS s.28; NB; NL s.22; PEI s.42; Yukon s.51). PIPEDA comparable-protection clauses; a foreign-order clause for AB s.107(5.1). | 1–2 weeks drafting, plus counsel | Canadian counsel, not priced |
| L2 | A PIA input pack for Alberta and Quebec (and C-36 if it passes); Alberta's s.64.2 information-security policy, filed once | 1–2 weeks | Nil |
| L3 | Per-user identity and the per-record access log (§3) | 1–2 weeks; server log 3–5 days | Nil |
| L4 | A breach runbook: notice to the clinic at the first reasonable opportunity, and the facts for its provincial notices and PIPEDA's 24-month record | 1–2 days | Nil |
| L5 | End-to-end encryption with clinic-held keys (§2) | 2–4 weeks | Engineering only |
| L6 | Hosting: none if the clinic's Canadian Microsoft 365 holds the data; otherwise a Canadian-region instance (§1) | 0, or 1–3 weeks | Tens of USD a month |
| L7 | Retention and destruction (§4); the secure-deletion wording already fixed by NJ | 2–3 days | Nil |
| L8 | Foreign-processing notice text for the clinic's privacy notice (a transfer to a processor is a use, and needs notice rather than new consent) | 1 day | Nil |
| L9 | Confidentiality undertakings and training for the company's own staff | 1 day | Nil |
| L10 | An EMR partner agreement and security review (for example a marketplace intake, a signed agreement, 1–2 weeks of credential set-up and up to 4 weeks of per-clinic enablement) | weeks to months of lead time | Not priced |
| L11 | SOC 2 Type I if a buyer or EMR partner asks, then Type II 6–12 months later | 3–6 months | USD 15–40k first year |
| L12 | Cyber or privacy liability insurance covering Canadian claims | broker | Not sourced |
| | **Total** | **About 6–14 weeks, plus 3–6 months for SOC 2 if asked** | **SOC 2 USD 15–40k; hosting tens of USD a month; counsel and insurance unpriced** |

## The clinic's own duties (the app can support them, not take them over)

- Sign the provincial agreement.
- Write the PIA, and in Alberta submit it, using the company's input pack.
- Name its privacy officer (in Quebec, the person in charge of protecting information).
- Decide on breaches and send the notices.
- Train its staff and collect their pledges (SK Reg s.5, MB Reg ss.6–7).
- Keep a written retention schedule (NS s.50, SK s.17).

## Decisions for Greig (only if a clinic asks)

1. **Whether to offer patient linkage at all.** *Recommend:* not for the first clinic. The EMR
   already holds the patient-to-lot link. *Alternative:* offer it on the clinic's own Canadian
   Microsoft 365, with L1–L5 and L7–L9.
2. **Where it lives.** *Recommend:* never on the company portal as built (§1).
3. **SOC 2.** *Recommend:* start only when a buyer or an EMR partner asks in writing.

## For a lawyer or commissioner to confirm

- Whether ciphertext held without the key is still personal health information for agreement
  purposes.
- Whether Cloudflare's transient decryption outside Alberta is "use outside Alberta" under Reg
  s.8(4).
- How PIPEDA applies to flows from Ontario, Nova Scotia, New Brunswick and Newfoundland custodians
  to a New Zealand processor.
- Whether remedies against a New Zealand company can be enforced.
- Quebec's logging rule for private practices, on which the professional bodies disagree.
- Alberta HIA s.66(1), shown as repealed while s.66(2) still refers to it.

## Not in scope

Anything for an inventory-only pilot (Plan NJ). The shared count itself (Plan NK). Registry and
adverse-event reporting, which stay in the EMR and the provincial systems.
