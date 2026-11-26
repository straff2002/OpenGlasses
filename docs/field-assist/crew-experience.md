# Crew experience

Your crew knows fixes that no manual has: the fault code that is almost always a loose plug, the board that
fails after a power cut, the check that saves an hour. The crew experience sheet puts that knowledge where the
glasses can use it. Each row is one case. Once you publish the sheet in your company portal, every phone in
the company picks it up the next time the app is opened, and answers from it below the manufacturer's manual,
marked as your company's experience.

Crew experience is part of the team and enterprise licences.

## How it reaches the crew

1. In the company portal, open the vault the sheet belongs to and download the template (`.xlsx` or `.csv`).
   There is one sheet per vault.
2. Fill it in using a spreadsheet app, or use the prompt below to turn notes into rows.
3. Upload it. The preview marks every row **ready**, **to fix** (with the reason and row number), or
   **changed by redaction**. You can edit a cell, leave a row out, or fix a model's spelling there.
4. Publish. Publishing approves every ready row you include, under your portal role.

On the phone, an answer that uses a row cites it as *Crew experience · model · date · approved by role*. When
an answer rests on crew experience alone, it opens with *"From your company's experience (not the
manufacturer's manual):"*. A row never outranks the manual's safety warnings. A row whose words clash with the
vault's safety notes needs a second confirmation before it can be published, and the phone keeps it marked.
The vault's line in Custom Vaults shows how many fixes it holds and when they were last updated.

## The columns

| Column | Fill in | What it is for |
|---|---|---|
| `id` | leave empty | The portal fills it in. Keep it when you edit and upload again, so a changed row updates the old one rather than adding a copy. |
| `brand` | if known | The manufacturer. |
| `model` | this or `equipment_type` | The model the fix is for. The row answers only for that model. |
| `equipment_type` | this or `model` | Use it alone for a fix that applies to a whole kind of equipment, such as "condensing unit". Pick from the list. |
| `fault_code` | if there is one | The code the unit shows, such as `E7`. Search finds the row by it. |
| `symptom` | yes | What the technician sees or hears. |
| `checked` | if useful | What was tried or ruled out first. |
| `fix` | yes | What fixed it. |
| `notes` | if useful | Anything else worth saying. Leave it empty and the portal writes "fault code: fix". |
| `how_sure` | recommended | In words: "fixed it every time", "most times" or "once". |
| `added_by` | optional | Who wrote the row. It is never shown on a phone. |
| `date` | optional | Shown to the person reviewing in the portal only. |

Leave customers, sites, addresses and phone numbers out. Site knowledge does not belong in crew experience,
and the portal removes phone numbers, e-mail addresses and anything that looks like a password or key. It
marks the row when it does, so nothing is changed without you seeing it.

A row can be up to 500 characters in `symptom`, `checked` and `fix`, and 2,000 in `notes`. A sheet can hold up
to 5,000 rows.

## What makes a good row

- **One case per row.** Two fixes for the same code are two rows, each with its own `how_sure`.
- **The model as it is printed on the unit.** The portal matches it against the vault's models and suggests
  the nearest spelling. If the vault doesn't know the model but your crew services it, choose **add as a model
  the company services**.
- **What a technician would say on the phone.** Short, plain, and specific: the part, the value, the order.
- **Honest about how often it works.** "Once" is useful too. The assistant says how sure the crew is.

## Three worked examples

These use made-up equipment.

| brand | model | equipment_type | fault_code | symptom | checked | fix | how_sure |
|---|---|---|---|---|---|---|---|
| Exampletherm | XR-200 | | E7 | Unit shows E7 a few minutes after start, fan stops | Flame sensor clean | Reseat the white two-pin plug on the control board; it works loose with vibration | fixed it every time |
| Exampletherm | XR-200 | | | Clicking from the cabinet, no heat | Gas supply on, filter clean | Replace the ignition relay on the left of the board | most times |
| | | condensing unit | | Fan runs, compressor hums and trips after a storm | Breaker reset once | Check the run capacitor; replace it if it is bulged or reads low | most times |

The first two answer only for the XR-200. The third answers for any condensing unit in the vault.

## Starting from what is already published

**Download current sheet** in the portal gives you the published rows with their ids. Edit it, add rows, and
upload it again: the preview shows what will change before you publish. History lets you go back to an earlier
version.

A company with no manuals can still use crew experience: start an **experience-only vault** in the portal. Its
model list comes from the sheet, and every answer from it is the company's experience.

## Turning notes into rows

A technician's typed or dictated notes can become rows with any chat assistant. Paste this prompt, then the
notes, and upload the result like any sheet. Check every row in the preview before you publish: the assistant
can get a model or a value wrong.

```text
Turn the service notes below into rows for a CSV file with exactly these columns, in this order:
brand,model,equipment_type,fault_code,symptom,checked,fix,notes,how_sure,added_by,date

Rules:
- One repair case per row. Split notes that describe more than one fix.
- Leave a column empty when the notes don't say. Never guess a model, code or value.
- Fill model, or equipment_type for a fix that applies to a whole kind of equipment.
- symptom: what the technician saw or heard. fix: what fixed it. checked: what was ruled out first.
- how_sure: "fixed it every time", "most times" or "once", only if the notes say how often.
- Leave out customer names, addresses, sites, phone numbers and e-mail addresses.
- Keep symptom, checked and fix under 500 characters each.
- Answer with the CSV only: a header row, then one row per case, quoted where a value contains a comma.

Notes:
```

## On the phone

There is nothing to set up on the phone. The rows arrive with the company's vaults and stay on the phone.
They are not shared further, they are not used while HIPAA mode is on, and they keep answering if the licence
lapses. A phone that leaves the company removes them, and so does removing the vault.
