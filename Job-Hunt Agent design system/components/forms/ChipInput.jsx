import React from "react";
import { Icon } from "../icons/Icon.jsx";

/**
 * ChipInput — token/tag entry for target roles, skills, locations. Type and
 * press Enter (or comma) to add; ✕ or Backspace to remove. Controlled via
 * `value` (string[]) + `onChange`.
 */
export function ChipInput({ label, value = [], onChange, placeholder = "Add and press Enter", hint, max, style, ...rest }) {
  const [draft, setDraft] = React.useState("");
  const [focus, setFocus] = React.useState(false);

  const commit = (raw) => {
    const t = raw.trim().replace(/,$/, "").trim();
    if (!t) return;
    if (value.includes(t)) { setDraft(""); return; }
    if (max && value.length >= max) return;
    onChange && onChange([...value, t]);
    setDraft("");
  };
  const removeAt = (i) => onChange && onChange(value.filter((_, idx) => idx !== i));

  const onKeyDown = (e) => {
    if (e.key === "Enter" || e.key === ",") { e.preventDefault(); commit(draft); }
    else if (e.key === "Backspace" && !draft && value.length) removeAt(value.length - 1);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, fontFamily: "var(--font-sans)", ...style }}>
      {label && <label style={{ fontSize: "var(--caption-size)", fontWeight: 600, color: "var(--text-secondary)" }}>{label}</label>}
      <div
        onClick={(e) => e.currentTarget.querySelector("input")?.focus()}
        style={{
          display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center",
          padding: "8px 10px", minHeight: 44, boxSizing: "border-box",
          borderRadius: "var(--radius-sm)",
          border: `1.5px solid ${focus ? "var(--brand-500)" : "var(--color-border-strong)"}`,
          background: "var(--color-surface)",
          boxShadow: focus ? "var(--focus-shadow)" : "none",
          transition: "border-color 120ms ease, box-shadow 120ms ease",
          cursor: "text",
        }}
      >
        {value.map((chip, i) => (
          <span key={i} style={{ display: "inline-flex", alignItems: "center", gap: 5, padding: "3px 6px 3px 10px", borderRadius: "var(--radius-pill)", background: "var(--brand-soft)", color: "var(--brand-700)", border: "1px solid var(--brand-soft-border)", fontSize: 13, fontWeight: 600 }}>
            {chip}
            <button type="button" onClick={(e) => { e.stopPropagation(); removeAt(i); }} aria-label={`Remove ${chip}`} style={{ appearance: "none", border: "none", background: "transparent", cursor: "pointer", padding: 0, color: "var(--brand-600)", display: "flex" }}>
              <Icon name="x" size={13} strokeWidth={2.6} />
            </button>
          </span>
        ))}
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
          onBlur={() => { setFocus(false); commit(draft); }}
          onFocus={() => setFocus(true)}
          placeholder={value.length ? "" : placeholder}
          style={{ flex: "1 1 80px", minWidth: 80, border: "none", outline: "none", background: "transparent", fontFamily: "var(--font-sans)", fontSize: "var(--body-size)", color: "var(--text-primary)", padding: "3px 0" }}
          {...rest}
        />
      </div>
      {hint && <span style={{ fontSize: "var(--caption-size)", color: "var(--text-tertiary)" }}>{hint}</span>}
    </div>
  );
}
