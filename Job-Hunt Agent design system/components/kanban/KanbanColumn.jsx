import React from "react";
import { StatusPill } from "../feedback/StatusPill.jsx";

const STAGE_LABEL = {
  new: "New", applied: "Applied", replied: "Replied",
  interview: "Interview", offer: "Offer", rejected: "Rejected",
};

/**
 * KanbanColumn — one pipeline lane for the Applications board. Header shows
 * the stage pill + count; children are the application cards, scrollable.
 */
export function KanbanColumn({ stage, count, width = 264, children, style, ...rest }) {
  const n = count != null ? count : React.Children.count(children);
  return (
    <div
      style={{
        flex: "none",
        width,
        display: "flex",
        flexDirection: "column",
        background: "var(--color-surface-sunken)",
        border: "1px solid var(--color-border)",
        borderRadius: "var(--radius-lg)",
        maxHeight: "100%",
        fontFamily: "var(--font-sans)",
        ...style,
      }}
      {...rest}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "12px 12px 8px" }}>
        <StatusPill context="stage" value={stage} size="sm" />
        <span style={{ marginLeft: "auto", fontFamily: "var(--font-mono)", fontSize: 12, fontWeight: 600, color: "var(--text-tertiary)" }}>{n}</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: "var(--space-2)", padding: "4px 8px 10px", overflowY: "auto" }}>
        {children}
      </div>
    </div>
  );
}
