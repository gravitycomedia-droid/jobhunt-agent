import React from "react";
import { Icon } from "../icons/Icon.jsx";

/**
 * EmptyState — shared zero-data pattern for Jobs, Shortlist, Matches,
 * Applications, and the Activity Log. Icon medallion + title + message +
 * optional primary action.
 */
export function EmptyState({ icon = "search", title, message, actionLabel, onAction, style, ...rest }) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        textAlign: "center",
        padding: "var(--space-16) var(--space-6)",
        fontFamily: "var(--font-sans)",
        ...style,
      }}
      {...rest}
    >
      <span style={{ width: 60, height: 60, borderRadius: "var(--radius-pill)", background: "var(--brand-soft)", color: "var(--brand-600)", display: "flex", alignItems: "center", justifyContent: "center", marginBottom: "var(--space-4)" }}>
        <Icon name={icon} size={28} strokeWidth={2} />
      </span>
      {title && <div style={{ fontSize: "var(--heading-sm-size)", lineHeight: "var(--heading-sm-line)", fontWeight: 700, color: "var(--text-primary)" }}>{title}</div>}
      {message && <div style={{ fontSize: "var(--body-sm-size)", lineHeight: "20px", color: "var(--text-secondary)", marginTop: 6, maxWidth: 280 }}>{message}</div>}
      {actionLabel && (
        <button
          type="button"
          onClick={onAction}
          style={{ appearance: "none", border: "none", cursor: "pointer", marginTop: "var(--space-5)", padding: "10px 18px", borderRadius: "var(--radius-md)", background: "var(--brand)", color: "var(--text-on-brand)", fontFamily: "var(--font-sans)", fontSize: 14, fontWeight: 700 }}
        >
          {actionLabel}
        </button>
      )}
    </div>
  );
}
