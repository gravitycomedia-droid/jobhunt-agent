import React from "react";
import { Icon } from "../icons/Icon.jsx";

function Logo({ company, logoUrl }) {
  const initial = (company || "?").trim().charAt(0).toUpperCase();
  return (
    <div
      style={{
        flex: "none",
        width: 42,
        height: 42,
        borderRadius: "var(--radius-md)",
        background: logoUrl ? `center/cover no-repeat url(${logoUrl})` : "var(--brand-soft)",
        border: "1px solid var(--color-border)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        color: "var(--brand-700)",
        fontWeight: 700,
        fontSize: 18,
      }}
      aria-hidden="true"
    >
      {!logoUrl && initial}
    </div>
  );
}

function Meta({ icon, children, mono }) {
  if (!children) return null;
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4, color: "var(--text-secondary)" }}>
      {icon && <Icon name={icon} size={13} strokeWidth={2} color="var(--text-tertiary)" />}
      <span
        style={{
          fontSize: "var(--caption-size)",
          fontWeight: mono ? 500 : "var(--caption-weight)",
          fontFamily: mono ? "var(--font-mono)" : "var(--font-sans)",
          color: mono ? "var(--text-primary)" : "var(--text-secondary)",
        }}
      >
        {children}
      </span>
    </span>
  );
}

export function JobCard({
  title,
  company,
  location,
  source,
  salary,
  postedAt,
  logoUrl,
  bookmarked = false,
  onBookmark,
  onPress,
  trailing,
  children,
  style,
  ...rest
}) {
  const clickable = !!onPress;
  return (
    <div
      onClick={onPress}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      style={{
        boxSizing: "border-box",
        width: "100%",
        background: "var(--color-surface)",
        border: "1px solid var(--color-border)",
        borderRadius: "var(--radius-lg)",
        boxShadow: "var(--elev-1)",
        padding: "var(--space-4)",
        display: "flex",
        flexDirection: "column",
        gap: "var(--space-3)",
        cursor: clickable ? "pointer" : "default",
        fontFamily: "var(--font-sans)",
        ...style,
      }}
      {...rest}
    >
      {/* header */}
      <div style={{ display: "flex", gap: "var(--space-3)", alignItems: "flex-start" }}>
        <Logo company={company} logoUrl={logoUrl} />
        <div style={{ flex: "1 1 auto", minWidth: 0 }}>
          <div
            style={{
              fontSize: "var(--title-size)",
              lineHeight: "var(--title-line)",
              fontWeight: "var(--title-weight)",
              color: "var(--text-primary)",
              overflow: "hidden",
              textOverflow: "ellipsis",
              display: "-webkit-box",
              WebkitLineClamp: 2,
              WebkitBoxOrient: "vertical",
            }}
          >
            {title}
          </div>
          <div style={{ fontSize: "var(--body-sm-size)", lineHeight: "var(--body-sm-line)", color: "var(--text-secondary)", fontWeight: 500, marginTop: 1 }}>
            {company}
          </div>
        </div>
        <div style={{ flex: "none", marginLeft: 2 }}>
          {trailing !== undefined
            ? trailing
            : onBookmark && (
                <button
                  type="button"
                  onClick={(e) => { e.stopPropagation(); onBookmark(); }}
                  aria-pressed={bookmarked}
                  aria-label="Save job"
                  style={{
                    appearance: "none", border: "none", background: "transparent", cursor: "pointer",
                    padding: 4, color: bookmarked ? "var(--brand-600)" : "var(--neutral-400)",
                  }}
                >
                  <Icon name="bookmark" size={20} strokeWidth={2} style={bookmarked ? { fill: "var(--brand-600)" } : undefined} />
                </button>
              )}
        </div>
      </div>

      {/* meta row */}
      {(location || postedAt || salary || source) && (
        <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: "8px 12px" }}>
          <Meta icon="mapPin">{location}</Meta>
          <Meta icon="clock">{postedAt}</Meta>
          {salary && <Meta mono>{salary}</Meta>}
          {source && (
            <span
              style={{
                marginLeft: "auto",
                display: "inline-flex", alignItems: "center", gap: 4,
                padding: "2px 8px", borderRadius: "var(--radius-pill)",
                background: "var(--info-soft)", color: "var(--info-text)", border: "1px solid var(--info-border)",
                fontSize: 11, fontWeight: 600,
              }}
            >
              <Icon name="externalLink" size={11} strokeWidth={2.2} />
              {source}
            </span>
          )}
        </div>
      )}

      {children}
    </div>
  );
}
