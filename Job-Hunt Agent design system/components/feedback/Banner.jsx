import React from "react";
import { Icon } from "../icons/Icon.jsx";

const TONE = {
  info:     { bg: "var(--info-soft)",     bd: "var(--info-border)",     fg: "var(--info-text)",     icon: "info" },
  success:  { bg: "var(--success-soft)",  bd: "var(--success-border)",  fg: "var(--success-text)",  icon: "check" },
  warning:  { bg: "var(--warning-soft)",  bd: "var(--warning-border)",  fg: "var(--warning-text)",  icon: "alertTriangle" },
  critical: { bg: "var(--critical-soft)", bd: "var(--critical-border)", fg: "var(--critical-text)", icon: "alertTriangle" },
};

/**
 * Banner — inline contextual message (e.g. stale-application warning,
 * guardrail notice). Tone-colored, optional action + dismiss.
 */
export function Banner({ tone = "info", title, children, actionLabel, onAction, onDismiss, style, ...rest }) {
  const t = TONE[tone] || TONE.info;
  return (
    <div
      role="status"
      style={{
        display: "flex",
        gap: 10,
        padding: "12px 14px",
        borderRadius: "var(--radius-md)",
        background: t.bg,
        border: `1px solid ${t.bd}`,
        fontFamily: "var(--font-sans)",
        ...style,
      }}
      {...rest}
    >
      <span style={{ flex: "none", color: t.fg, marginTop: 1 }}><Icon name={t.icon} size={18} strokeWidth={2.2} /></span>
      <div style={{ flex: "1 1 auto", minWidth: 0 }}>
        {title && <div style={{ fontSize: "var(--body-sm-size)", lineHeight: "20px", fontWeight: 700, color: t.fg }}>{title}</div>}
        {children && <div style={{ fontSize: "var(--caption-size)", lineHeight: "18px", color: t.fg, opacity: 0.9, marginTop: title ? 2 : 0 }}>{children}</div>}
        {actionLabel && (
          <button
            type="button"
            onClick={onAction}
            style={{ appearance: "none", border: "none", background: "transparent", cursor: "pointer", padding: 0, marginTop: 8, color: t.fg, fontFamily: "var(--font-sans)", fontSize: 13, fontWeight: 700, textDecoration: "underline", textUnderlineOffset: 2 }}
          >
            {actionLabel}
          </button>
        )}
      </div>
      {onDismiss && (
        <button type="button" onClick={onDismiss} aria-label="Dismiss" style={{ appearance: "none", border: "none", background: "transparent", cursor: "pointer", padding: 2, color: t.fg, flex: "none", opacity: 0.7 }}>
          <Icon name="x" size={16} strokeWidth={2.2} />
        </button>
      )}
    </div>
  );
}
