import React from "react";
import { Icon } from "../icons/Icon.jsx";

/* tone → semantic token trio */
const TONE = {
  success:  { bg: "var(--success-soft)",  fg: "var(--success-text)",  bd: "var(--success-border)",  dot: "var(--success-fill)" },
  warning:  { bg: "var(--warning-soft)",  fg: "var(--warning-text)",  bd: "var(--warning-border)",  dot: "var(--warning-fill)" },
  critical: { bg: "var(--critical-soft)", fg: "var(--critical-text)", bd: "var(--critical-border)", dot: "var(--critical-fill)" },
  info:     { bg: "var(--info-soft)",     fg: "var(--info-text)",     bd: "var(--info-border)",     dot: "var(--info-fill)" },
  neutral:  { bg: "var(--neutral-soft)",  fg: "var(--neutral-text)",  bd: "var(--neutral-chip-border)", dot: "var(--neutral-fill)" },
};

/* context + value → { tone, label, icon } */
const MAP = {
  verdict: {
    apply:   { tone: "success",  label: "Apply",   icon: "check" },
    stretch: { tone: "warning",  label: "Stretch", icon: "arrowUpRight" },
    skip:    { tone: "critical", label: "Skip",    icon: "x" },
  },
  guardrail: {
    pass: { tone: "success",  label: "Guardrail pass", icon: "check" },
    fail: { tone: "critical", label: "Guardrail fail", icon: "alertTriangle" },
  },
  stage: {
    new:       { tone: "neutral",  label: "New" },
    applied:   { tone: "info",     label: "Applied" },
    replied:   { tone: "info",     label: "Replied" },
    interview: { tone: "info",     label: "Interview" },
    offer:     { tone: "success",  label: "Offer" },
    rejected:  { tone: "critical", label: "Rejected" },
  },
};

export function StatusPill({ context = "stage", value, size = "md", showIcon = true, style, ...rest }) {
  const cfg = (MAP[context] && MAP[context][value]) || { tone: "neutral", label: String(value ?? "") };
  const t = TONE[cfg.tone];
  const sm = size === "sm";

  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: sm ? 4 : 5,
        padding: sm ? "2px 8px" : "3px 10px",
        borderRadius: "var(--radius-pill)",
        background: t.bg,
        color: t.fg,
        border: `1px solid ${t.bd}`,
        fontFamily: "var(--font-sans)",
        fontSize: sm ? 11 : 12,
        lineHeight: 1.2,
        fontWeight: 600,
        letterSpacing: "0.005em",
        whiteSpace: "nowrap",
        boxSizing: "border-box",
        ...style,
      }}
      {...rest}
    >
      {context === "stage" ? (
        <span style={{ width: sm ? 5 : 6, height: sm ? 5 : 6, borderRadius: "50%", background: t.dot, flex: "none" }} />
      ) : (
        showIcon && cfg.icon && <Icon name={cfg.icon} size={sm ? 12 : 13} strokeWidth={2.4} />
      )}
      {cfg.label}
    </span>
  );
}
