import React from "react";

/**
 * FormField — labeled text input with hint + error states. Every text-entry
 * surface (Profile, Settings, Sign In) uses this.
 */
export function FormField({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  hint,
  error,
  required = false,
  disabled = false,
  multiline = false,
  rows = 3,
  id,
  style,
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const fid = id || (label ? `ff-${label.replace(/\s+/g, "-").toLowerCase()}` : undefined);
  const borderColor = error ? "var(--critical-fill)" : focus ? "var(--brand-500)" : "var(--color-border-strong)";
  const control = {
    boxSizing: "border-box",
    width: "100%",
    padding: "11px 12px",
    borderRadius: "var(--radius-sm)",
    border: `1.5px solid ${borderColor}`,
    background: disabled ? "var(--neutral-100)" : "var(--color-surface)",
    color: "var(--text-primary)",
    fontFamily: "var(--font-sans)",
    fontSize: "var(--body-size)",
    lineHeight: "var(--body-line)",
    outline: "none",
    boxShadow: focus && !error ? "var(--focus-shadow)" : "none",
    transition: "border-color 120ms ease, box-shadow 120ms ease",
    resize: multiline ? "vertical" : undefined,
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, fontFamily: "var(--font-sans)", ...style }}>
      {label && (
        <label htmlFor={fid} style={{ fontSize: "var(--caption-size)", fontWeight: 600, color: "var(--text-secondary)" }}>
          {label}
          {required && <span style={{ color: "var(--critical-fill)", marginLeft: 3 }}>*</span>}
        </label>
      )}
      {multiline ? (
        <textarea id={fid} value={value} onChange={onChange} placeholder={placeholder} rows={rows} disabled={disabled}
          onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} style={control} {...rest} />
      ) : (
        <input id={fid} type={type} value={value} onChange={onChange} placeholder={placeholder} disabled={disabled}
          onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} style={control} {...rest} />
      )}
      {error ? (
        <span style={{ fontSize: "var(--caption-size)", color: "var(--critical-text)", fontWeight: 500 }}>{error}</span>
      ) : hint ? (
        <span style={{ fontSize: "var(--caption-size)", color: "var(--text-tertiary)" }}>{hint}</span>
      ) : null}
    </div>
  );
}
