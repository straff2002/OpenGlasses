# Plan LJ — Tell Me When It's for Sale (an announced product that isn't listed yet, and deals that meet your rules)

**Status:** 📝 Drafted 2026-11-11. Nothing built. The [decisions](#decisions-for-greig-open) are recommendations and
are still open.
**Track:** Everyday assistant. Off until the wearer makes a watch.
**Builds on:** Plan [IZ](IZ-product-lookup-and-price-alerts.md) (`product_lookup`, `ProductQuery`,
`SearchResultSet`, `PriceExtractor`, `PriceWatch` and `PriceWatchChecker`: drafted, nothing built), Plan
[JO](JO-watchers.md) (`Watcher`, `WatcherKind`, `Observation`, `WatchMatcher`, `WatchCadence`,
`WatchDeliveryPolicy`, `WatchRunner`: drafted, nothing built), Plan [GF](GF-recipe-add-ons.md) (recipe add-ons:
library built, not wired), Plan [KZ](KZ-provider-web-search.md) (the provider's own search inside a turn),
`BoundedHTTPClient`, `NotificationDigestService`, `AgentNotificationQueue`.
**Sits beside:** Plan [LL](LL-always-on-home-agent.md) (the always-on tier, which is the only place a 30-minute
cadence or repeated alerts can live), Plan [LK](LK-reading-mail-the-decision.md) (deal emails are mail, and mail is
not a source here).

---

## Trigger

An example list of routines a cloud personal agent runs, which the owner shared on 2026-11-11, included two
shopping jobs this app cannot do:

- **Waiting for a product to go on sale.** An accessory was announced over a year ago and has never been
  orderable. The agent checks twice a day and, once it lists, alerts every 30 minutes until the owner acts.
- **Deal hunting by rules.** Clearance at a large discount or an obvious pricing error, at named retailers,
  only for items the retailer itself sells and ships (never a marketplace seller), with a brand watchlist.

Plan IZ's price watch asks "is it cheaper than X?" of a product that is already on sale. Neither "is it on sale
at all yet?" nor "does this listing meet my rules?" has a condition, and the only scheduler that could check
runs a model turn while the app is alive.

## Outcome

- "Tell me when the luggage rack for my scooter goes on sale." → "Okay. I'll check twice a day and tell you when
  a store lists it as in stock or on pre-order. Right now I can only find the announcement." The watch says which
  sources it checks.
- When a listing appears: "The luggage rack is listed at the maker's own store, on pre-order, 89 dollars. The
  link is on your phone." Said once. It is in the digest until the wearer opens or dismisses it, and it never
  goes stale.
- If only one source says so and it is not the maker or a named retailer: "One store might be listing the
  luggage rack. I couldn't confirm it anywhere else." This is a "possibly" finding, never the same wording as a
  confirmed one.
- "Tell me about deals on Brand X power tools at 70% off or more, sold by the store itself." → a deal watch
  with typed rules. A finding names the store, the price, the reference price it is measured against, and who
  sells it: "Store A has the Brand X drill at 79, down from 299. Sold and shipped by Store A."
- A listing whose seller can't be read **fails the seller rule**. It is never assumed to be the retailer.
- "What are you watching?" lists availability and deal watches next to JO's other watchers; "stop watching the
  rack" ends one.
- It never buys, never adds to a cart, never signs in to a store, and never says "pricing error" as fact.

## What exists, and what doesn't (verified 2026-11-11 at main 2d936d2)

**Exists:**
- `BarcodeScannerTool` (`scan_code`), `WebSearchTool` (`web_search`: Perplexity → Tavily → Brave → SearXNG →
  Tavily keyless → DuckDuckGo, free text only), both in `untrustedOutputTools`
  (`Services/PromptInjectionPolicy.swift`).
- `ProviderSearchPolicy` (Plan KZ, built 2026-11-10): with no search key, the chosen provider runs its own search
  **inside a model turn** and cites pages. That suits the wearer asking "is it out yet?" in conversation. It is
  not usable for a routine check, which JO keeps free of model calls.
- `BoundedHTTPClient` (`Services/Security/BoundedHTTPClient.swift`): public HTTPS only, DNS-pinned, profiles with
  byte caps and MIME lists (`qrContext`, `signedCatalog`, `skillPack`, `vaultArchive`, `orgProfile`,
  `activationKey`, `internalSkillPack`). No shopping or add-on profile yet.
- GF's library under `Services/AddOns/`: `RecipeAddOnManifest` with `http`, `extract` and `say` steps,
  `RecipeAddOnValidator`, `RecipeRunner`, `RecipeSandbox`, `AddOnHTTPTransport`, `AddOnDomainRule`. **Not wired
  into the app**: no store, tool wrapper or install sheet.
- Delivery: `NotificationDigestService`, `DigestSource` (`calendar`, `geofence`, `proactive`, `agent`,
  `reminder`, `sync`, `goal`), `AgentNotificationQueue`, `NotificationPriority`.

**Doesn't exist:**
- Anything from IZ or JO: no `ProductQuery`, `SearchResultSet`, `PriceWatch`, `Watcher` or `WatchRunner`.
- Background execution: no `BGTaskScheduler`, and `UIBackgroundModes` is `audio`, `bluetooth-central`,
  `external-accessory`. A check runs only while the app is alive.
- Push. No `aps-environment` entitlement, no `registerForRemoteNotifications`.
- Any reading of a retailer page's stock state or seller.

**What a phone can honestly reach.** It can use search results (titles, snippets, URLs) from the keyed search
providers, and, through a GF add-on, a public machine-readable product file where a maker's or retailer's store
offers one. Some store platforms publish product data as JSON without a sign-in, and some pages carry
schema.org `Offer` data. It can't sign in to a store, can't run a page's JavaScript, can't get past bot checks,
and has no browser on the wearer's home network. Those belong to a home agent (Plan LL) and stay its business.

## Design

### 1 · Two new watcher kinds, one checker each

Following IZ's note that a price watch becomes a JO watcher kind:

```swift
enum WatcherKind {                     // JO's enum gains:
    case availability(AvailabilityWatch)
    case deal(DealWatch)
}
struct AvailabilityWatch: Codable {
    var product: ProductQuery          // IZ: name, brand, variant, gtin?
    var makerHosts: [String]           // the maker's own store, if the wearer or a search named one
    var retailers: [String]            // hosts the wearer named; empty = any
    var counts: Set<ListingState>      // default [.inStock, .preorder]
}
struct DealWatch: Codable {
    var query: String                  // "Brand X power tools", or a ProductQuery
    var retailers: [String]            // required: a deal watch names its stores
    var rules: DealRules
}
struct DealRules: Codable {
    var minDiscountPercent: Int?       // measured against a reference price (§3)
    var maxPrice: Decimal?
    var sellerMustBeRetailer: Bool     // default true
    var brands: [String]               // empty = any
}
```

### 2 · Reading a listing (`ListingReader`, pure)

`SearchResultSet` results (IZ) and GF add-on output both become `ListingObservation { host, title, url, state,
price?, wasPrice?, seller, observedAt, sourceKind }`:

- `state`: `.inStock`, `.preorder`, `.outOfStock`, `.announcedOnly`, `.unknown`. Read from fixed, per-language
  phrases in titles and snippets ("in stock", "add to cart", "pre-order", "coming soon", "notify me",
  "sold out") or from structured `availability` values where an add-on returns them. Contradictory or missing
  phrases give `.unknown`.
- `seller`: `.retailer`, `.marketplace(name?)`, `.unknown`. `.retailer` needs positive text ("sold and shipped
  by <host's store>", or the store's own first-party label in structured data). A marketplace phrase ("sold by",
  "ships from" naming someone else, "third-party seller") gives `.marketplace`. Anything else is `.unknown`.
- `sourceKind`: `.maker` (host in `makerHosts`), `.namedRetailer`, `.otherStore`, `.news` (a news or review
  site, which can announce but never lists).
- Prices go through IZ's `PriceExtractor`; a "was"/"RRP"/"list price" amount becomes `wasPrice`.

Observation text is untrusted. It is phrased from typed fields and never passed to a model as instructions.

### 3 · Deciding (`AvailabilityChecker`, `DealChecker`, pure)

**Availability fires** when, for the first time, an observation's `state` is in `counts` and either:
- it comes from `.maker` or `.namedRetailer`, or
- two different `.otherStore` hosts agree within one check.

A single `.otherStore` hit is a `possibly` finding, said as such and counted separately (decision 3). A `.news`
source never fires. After firing, the watch moves to `.listed` and stops checking, unless the listing goes
`.outOfStock` within a day (decision 5).

**A deal passes** only when every rule holds on what the observation actually says:
- the brand is in `brands` (matched on the title's words, not guessed);
- `sellerMustBeRetailer` → `seller == .retailer` (`.unknown` fails);
- `maxPrice` holds;
- `minDiscountPercent` against a **reference price**: the observation's own `wasPrice`, or the lowest price this
  watch has recorded for the same URL over at least three checks. With neither, the discount rule fails and the
  finding is not made ("I can't tell what it was before").

The word "pricing error" is never produced. A discount above 90% against our own history is phrased as "much
lower than I've seen it before" with the reference stated.

Fingerprints (JO's `seen`) are host + URL + state, or host + URL + price for deals, so the same listing is told
once.

### 4 · Sources and cadence

- **Search** (default): `WebSearchTool.structured` from IZ P1, with a query per watch (brand + name + "buy" /
  "pre-order"; GTIN when known), restricted to `retailers` + `makerHosts` where the provider supports a site
  filter. One search per watch per check. Keyed providers only for routine checks (IZ decision 5's concern:
  DuckDuckGo rarely carries prices or stock text).
- **Add-on** (once GF P2 wires add-ons in): an add-on for one store's public product file, with an
  `.recipeAddOn` profile (≤ 256 KB, JSON, per GF). It returns typed state, price and seller, which is better
  data than a snippet. The add-on is ordinary GF: visible, approved by the wearer, removable.
- **In conversation**: "is it out yet?" may use KZ's provider search like any question. The answer is not
  recorded as a check.
- **Cadence on the phone:** twice a day, in IZ's morning and evening slots, under IZ's daily search budget
  (default 10), skipped under `PowerPosture.reserve`, offline or Local Only. JO's runner picks up an overdue
  check on foreground or after a wake word. The watch's confirmation says this: "I'll check when the app is
  running, about twice a day."
- **Always-on cadence:** every 30 minutes, and a repeat reminder after a listing until the wearer answers, need a
  process that is always running. They exist only through Plan LL. The phone never pretends to them.

### 5 · Delivery

- An availability finding goes in the digest as a new `DigestSource.shopping` (IZ's case) at `.high`, so it does
  not go stale. It is spoken through `agentNotificationQueue.enqueue` at the next moment `WatchDeliveryPolicy`
  allows. With no glasses, it is a local notification. A `possibly` finding is `.medium` and digest-only.
- A deal finding is `.medium`, digest-first. It is spoken only if the wearer asked for spoken deals on that
  watch, and it counts towards JO's daily cap of three.
- The phone card shows store, state, price, reference price, seller and the link. **Opening the link is the
  wearer's tap.** Nothing is fetched from the link on the wearer's behalf after the finding.

### 6 · Safety and privacy

- `product_lookup`'s new actions (`watch_availability`, `watch_deal`) are local writes and the checks are reads.
  No purchase, cart, account, coupon code entry, sign-up or "notify me" form is ever submitted, including by an
  add-on (GF has no form-post capability for this kind, and the add-on's permissions sheet would show one).
- Search queries pass `EgressScreen` on the native seam, as IZ proposes for `product_lookup`.
- `PrivacyLog.shopping(...)` records counts and provider only, never the product or query (IZ's rule).
- Local Only and HIPAA mode: the watches pause, said on the Watching screen.

## Phases (one PR each)

### P0 — the pure core (headless)

Depends on IZ P0 (`SearchResultSet`, `PriceExtractor`, `ProductQuery`).
- `ListingObservation`, `ListingState`, `SellerKind`, `ListingReader` (phrase tables, structured `availability`
  mapping), `AvailabilityWatch`, `DealWatch`, `DealRules`, `AvailabilityChecker`, `DealChecker`, the reference
  price rule, the phraser.
- **Exit tests:** announcement-only news hits never fire; a maker page's "pre-order" fires once; one unknown store
  is `possibly`; two unknown stores agree and fire; a marketplace seller fails `sellerMustBeRetailer`; a missing
  seller fails; a 72% discount with `wasPrice` passes; the same discount with no reference fails; the
  "much lower than before" wording at 90%+; no output ever contains "pricing error"; fingerprints dedupe a
  repeated listing.

### P1 — watches on the phone (headless, wired)

Depends on JO P0 (watcher store, runner, delivery) and IZ P1 (`WebSearchTool.structured`).
- The two kinds in `WatcherStore` and `WatchRunner`; `product_lookup` actions `watch_availability`,
  `watch_deal`; the digest case and card; the Watching screen rows with their honest cadence line.
- Tests over a fake clock and fake search: twice-daily checks, budget stop, reserve skip, one spoken
  availability finding, a deal held in the digest, Local Only pausing.

### P2 — a store's own data through an add-on

Depends on GF P2 (store, wrapper, install sheet).
- A `.recipeAddOn` profile in `BoundedHTTPClient` if GF P2 has not added it; a starter add-on for one store
  platform's public product file; `ListingReader` accepting typed add-on output. A fixture per platform.

### P3 — hand-off to the always-on tier

Depends on Plan LL P2.
- "Watch it at home": the watch definition is sent to the home agent, which checks every 30 minutes and repeats
  the reminder after a listing. Results come back as LL's typed watch results and are delivered by P1's rules.

### P4 — device pass (owed)

- Three real watches over two weeks: a product already orderable (should fire on the first check), one that is
  announced only (should stay silent), and a deal watch at a named retailer. Record each provider's hit rate for
  stock and seller text, and what happens with the phone locked overnight (expected: checked on unlock).

## Decisions for Greig (open)

Recommendations first.

1. **JO watcher kinds, IZ's checker pieces.** Availability and deals are two new `WatcherKind`s, reusing IZ's
   search and price code, not a second scheduler.
2. **Twice a day on the phone**, as IZ decision 2 recommends. A 30-minute cadence only through LL.
3. **Fire rule:** maker or named retailer, or two other stores agreeing. One other store is a "possibly".
4. **Unknown seller fails** the retailer-only rule. A deal the wearer can't trust is not a deal.
5. **After a listing, stop**, except that if it goes out of stock within a day the watch rearms once and says so.
6. **An availability finding is outside JO's daily cap of three**, because the wearer asked for exactly this.
   Deal findings count towards the cap.
7. **Deals need named stores and a query.** No whole-catalogue clearance sweep: it needs the store's own feed or
   a signed-in browser, which a phone doesn't have.

## Risks

- **Snippets lie or lag.** Search snippets can show a stale "in stock" or miss a new listing for days. The fire
  rule and the "possibly" wording keep false alarms honest. The device pass measures it, and the add-on route
  exists because snippets alone may not be good enough.
- **Seller text is often absent** from a snippet, so a retailer-only deal watch may rarely pass. That is the
  correct failure. An add-on for the store's own data is the fix.
- **Retailer terms.** No scraping of retailer pages. An add-on reads only what a store publishes for machines,
  at the add-on's declared rate.
- **Expectations.** A wearer used to an always-on agent expects 30-minute checks. The confirmation and Watching
  screen say what the phone does, and point to LL.

## Out of scope

Buying, carts, accounts, coupon codes, "notify me" sign-ups, marketplace listings as a source of deals, price
history from third-party trackers, deal emails (Plan [LK](LK-reading-mail-the-decision.md)), browsing behind a
sign-in, and any cadence the phone can't keep.
