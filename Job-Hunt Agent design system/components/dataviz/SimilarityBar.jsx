import React from "react";

/**
 * SimilarityBar — horizontal 0–100 bar for resume↔job similarity, keyword
 * coverage, etc. Color follows verdict thresholds unless `color` given.
 */
export function SimilarityBar({ value = 0, label, showValue = true, color, height = 8, style, ...rest }) {
  const v = Math.max(0, Math.min(100, Math.round(value)));
  const fill = color || (v >= 75 ? "var(--success-fill)" : v >= 50 ? "var(--warning-fill)" : "var(--critical-fill)");
  return (
    <div style={{ fontFamily: "var(--font-sans)", ...style }} {...rest}>
      {(label || showValue) && (
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", marginBottom: 6 }}>
          {label && <span style={{ fontSize: "var(--caption-size)", fontWeight: 600, color: "var(--text-secondary)" }}>{label}</span>}
          {showValue && <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, fontWeight: 600, color: "var(--text-primary)" }}>{v}%</span>}
        </div>
      )}
      <div style={{ width: "100%", height, borderRadius: "var(--radius-pill)", background: "var(--neutral-200)", overflow: "hidden" }}>
        <div style={{ width: `${v}%`, height: "100%", borderRadius: "var(--radius-pill)", background: fill, transition: "width 500ms ease" }} />
      </div>
    </div>
  );
}
