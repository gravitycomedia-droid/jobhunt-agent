import React from "react";
import { Icon } from "../icons/Icon.jsx";

/**
 * DiffRow — one tailoring change: original bullet vs tailored bullet.
 * When `guardrailFail` is set, the tailored text is highlighted critical
 * (a fabricated / unverifiable claim the guardrail rejected).
 */
export function DiffRow({ original, tailored, guardrailFail = false, unchanged = false, style, ...rest }) {
  return (
    <div
      style={{
        border: "1px solid var(--color-border)",
        borderRadius: "var(--radius-md)",
        overflow: "hidden",
        background: "var(--color-surface)",
        fontFamily: "var(--font-sans)",
        ...style,
      }}
      {...rest}
    >
      {/* original */}
      <div style={{ display: "flex", gap: 8, padding: "10px 12px", background: "var(--neutral-50)", borderBottom: "1px solid var(--color-border)" }}>
        <span style={{ flex: "none", fontFamily: "var(--font-mono)", fontWeight: 700, color: "var(--neutral-400)", lineHeight: "20px" }}>–</span>
        <span style={{ fontSize: "var(--body-sm-size)", lineHeight: "20px", color: "var(--text-tertiary)", textDecoration: unchanged ? "none" : "line-through", textDecorationColor: "var(--neutral-300)" }}>
          {original}
        </span>
      </div>
      {/* tailored */}
      <div style={{ display: "flex", gap: 8, padding: "10px 12px", background: guardrailFail ? "var(--critical-soft)" : "transparent" }}>
        <span style={{ flex: "none", fontFamily: "var(--font-mono)", fontWeight: 700, color: guardrailFail ? "var(--critical-fill)" : "var(--success-fill)", lineHeight: "20px" }}>+</span>
        <span style={{ flex: "1 1 auto" }}>
          <span
            style={{
              fontSize: "var(--body-sm-size)",
              lineHeight: "20px",
              fontWeight: 500,
              color: guardrailFail ? "var(--critical-text)" : "var(--text-primary)",
              background: guardrailFail ? "var(--guardrail-fail-highlight)" : "transparent",
              borderRadius: 3,
              padding: guardrailFail ? "1px 3px" : 0,
              boxDecorationBreak: "clone",
              WebkitBoxDecorationBreak: "clone",
            }}
          >
            {tailored}
          </span>
          {guardrailFail && (
            <span style={{ display: "inline-flex", alignItems: "center", gap: 4, marginLeft: 6, fontSize: 11, fontWeight: 600, color: "var(--critical-text)", verticalAlign: "middle" }}>
              <Icon name="alertTriangle" size={12} strokeWidth={2.4} />
              Guardrail fail
            </span>
          )}
        </span>
      </div>
    </div>
  );
}
