# Example vault: bottling line start-of-shift check

A small Field Assist vault whose one procedure runs **with no assistant**: every answer is typed
(numbers with a readable range and a spec, a choice, a yes or no, photos and a code), and every
step that branches lets the app choose the route from the answer. It is the worked example for
"Answers and routes the app decides" in Step 4 of the
[vault guide](../../../docs/field-assist-vault-guide.md), and `ProcedureAnswerExampleTests`
imports it and walks it headlessly.

```
bottling-line-check/
├── manifest.json            id bottling_line_check · two core files · one procedure
├── safety.md                core: lock-out, eye protection, glass and spills
├── line_values.md           core: the readable range and spec of each reading
└── procedures/
    └── start_of_shift_check.json
```

The line, its values and its limits are generic and invented for the example. A real site writes
its own limits from its product specifications; the app records the check, and it does not make a
site's quality plan compliant.

What the procedure shows:

- `confirm_line_clear`: a `yes_no` answer; `is: "no"` sends the operator to clear the line first.
- `check_co2`: a critical `number` with `plausible` [0, 6] and `spec` [2.4, 2.8]. A reading of 42
  is asked again; 2.9 is recorded as out of spec, read back when spoken, and needs a corrective
  note before the run goes on to adjust the carbonation and retest.
- `check_brix`: a rule that reads two answers: Brix below 10.5 **and** CO2 below 2.5 holds the
  batch, listed before the plain "Brix low" route so it wins.
- `check_fill_height`: `out_of_spec` true / false, so the spec in the answer is the only place the
  limit is written.
- `photo_first_bottles`: one to three photos, attached to the job and listed by id; nothing
  assesses them.
- `check_label`: a `choice` with synonyms ("straight", "crooked") and an `in` rule.
- `record_date_code`: a `code`, scanned or typed.
- `sign_off`: the last step asks for confirmation, as any procedure's can.
