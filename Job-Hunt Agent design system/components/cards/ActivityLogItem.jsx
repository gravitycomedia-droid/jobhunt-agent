import React from "react";
import { Icon } from "../icons/Icon.jsx";

const KIND = {
  agent:     { icon: "bot",   bg: "var(--brand-soft)",    fg: "var(--brand-700)" },
  match:     { icon: "target",bg: "var(--info-soft)",     fg: "var(--info-text)" },
  applied:   { icon: "check", bg: "var(--success-soft)",  fg: "var(--success-text)" },
  warning:   { icon: "alertTriangle", bg: "var(--warning-soft)", fg: "var(--warning-text)" },
  rejected:  { icon: "x",     bg: "var(--critical-soft)", fg: "var(--critical-text)" },
  info:      { icon: "info",  bg: "var(--neutral-soft)",  fg: "var(--neutral-text)" },
};

/**
 * ActivityLogItem — one entry in the Agent Activity Log. Icon by kind,
 * title, optional detail, right-aligned timestamp, with a connecting
 * timeline rail unless `last`.
 */
export function ActivityLogItem({ kind = "info", title, detail, timestamp, last = false, style, ...rest }) {
  const k = KIND[kind] || KIND.info;
  return (
    <div style={{ display: "flex", gap: 12, fontFamily: "var(--font-sans)", ...style }} {...rest}>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", flex: "none" }}>
        <span style={{ width: 30, height: 30, borderRadius: "var(--radius-pill)", background: k.bg, color: k.fg, display: "flex", alignItems: "center", justifyContent: "center" }}>
          <Icon name={k.icon} size={16} strokeWidth={2.2} />
        </span>
        {!last && <span style={{ flex: 1, width: 2, background: "var(--color-border)", marginTop: 4, minHeight: 12 }} />}
      </div>
      <div style={{ flex: "1 1 auto", paddingBottom: last ? 0 : "var(--space-4)" }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ fontSize: "var(--body-sm-size)", lineHeight: "20px", fontWeight: 600, color: "var(--text-primary)" }}>{title}</span>
          {timestamp && <span style={{ marginLeft: "auto", flex: "none", fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-tertiary)" }}>{timestamp}</span>}
        </div>
        {detail && <div style={{ fontSize: "var(--caption-size)", lineHeight: "18px", color: "var(--text-secondary)", marginTop: 2 }}>{detail}</div>}
      </div>
    </div>
  );
}
