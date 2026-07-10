import React from "react";
import { Icon } from "../icons/Icon.jsx";

const DEFAULT_DESTINATIONS = [
  { key: "home",         label: "Home",     icon: "home" },
  { key: "jobs",         label: "Jobs",     icon: "briefcase" },
  { key: "matches",      label: "Matches",  icon: "target" },
  { key: "applications", label: "Track",    icon: "columns" },
  { key: "profile",      label: "Profile",  icon: "user" },
];

/**
 * AppShell — portrait-first in-app frame: optional top app-bar, a
 * scrollable content region, and the 5-destination bottom nav.
 * Fills its parent; drop it inside a device frame for previews.
 */
export function AppShell({
  active = "home",
  onNavigate,
  destinations = DEFAULT_DESTINATIONS,
  title,
  trailing,
  showHeader = true,
  children,
  style,
  ...rest
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100%",
        width: "100%",
        background: "var(--color-bg)",
        fontFamily: "var(--font-sans)",
        color: "var(--text-primary)",
        overflow: "hidden",
        ...style,
      }}
      {...rest}
    >
      {showHeader && (
        <header
          style={{
            flex: "none",
            height: "var(--header-h)",
            display: "flex",
            alignItems: "center",
            gap: 8,
            padding: "0 var(--screen-pad-x)",
            background: "var(--color-surface)",
            borderBottom: "1px solid var(--color-border)",
          }}
        >
          <span style={{ fontSize: "var(--heading-sm-size)", lineHeight: 1, fontWeight: 700, letterSpacing: "-0.01em" }}>
            {title}
          </span>
          <span style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 4 }}>{trailing}</span>
        </header>
      )}

      <main
        style={{
          flex: "1 1 auto",
          overflowY: "auto",
          WebkitOverflowScrolling: "touch",
          padding: "var(--space-4) var(--screen-pad-x)",
          paddingBottom: "calc(var(--bottomnav-h) + var(--space-6))",
        }}
      >
        {children}
      </main>

      <nav
        style={{
          flex: "none",
          height: "var(--bottomnav-h)",
          display: "grid",
          gridTemplateColumns: `repeat(${destinations.length}, 1fr)`,
          alignItems: "center",
          background: "var(--color-surface)",
          borderTop: "1px solid var(--color-border)",
          boxShadow: "var(--elev-3)",
          position: "relative",
          zIndex: 2,
        }}
      >
        {destinations.map((d) => {
          const on = d.key === active;
          return (
            <button
              key={d.key}
              type="button"
              onClick={() => onNavigate && onNavigate(d.key)}
              aria-current={on ? "page" : undefined}
              style={{
                appearance: "none",
                border: "none",
                background: "transparent",
                cursor: "pointer",
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                gap: 3,
                padding: "6px 2px",
                minHeight: "var(--touch-min)",
                color: on ? "var(--nav-active)" : "var(--nav-inactive)",
                fontFamily: "var(--font-sans)",
              }}
            >
              <span
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  width: 40,
                  height: 24,
                  borderRadius: "var(--radius-pill)",
                  background: on ? "var(--brand-soft)" : "transparent",
                  transition: "background 120ms ease",
                }}
              >
                <Icon name={d.icon} size={21} strokeWidth={on ? 2.4 : 2} />
              </span>
              <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600, letterSpacing: "0.01em" }}>{d.label}</span>
            </button>
          );
        })}
      </nav>
    </div>
  );
}
