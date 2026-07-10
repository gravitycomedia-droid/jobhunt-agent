One pill, three semantic contexts — use for match verdicts, guardrail results, and Kanban pipeline stages. Never hand-roll a colored chip; drive it with `context` + `value` so tone stays consistent app-wide.

```jsx
<StatusPill context="verdict" value="apply" />
<StatusPill context="guardrail" value="fail" />
<StatusPill context="stage" value="interview" size="sm" />
```

- `context="verdict"` → apply (success) · stretch (warning) · skip (critical), leading glyph
- `context="guardrail"` → pass (success) · fail (critical), leading glyph
- `context="stage"` → new (neutral) · applied/replied/interview (info) · offer (success) · rejected (critical), leading dot
- `size="sm"` for dense card rows; `showIcon={false}` to drop the glyph on verdict/guardrail.
