import React from "react";

export interface BannerProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Tone / severity. Default info. */
  tone?: "info" | "success" | "warning" | "critical";
  /** Bold first line. */
  title?: string;
  /** Body message. */
  children?: React.ReactNode;
  /** Inline action link label. */
  actionLabel?: string;
  /** Action handler. */
  onAction?: () => void;
  /** When set, shows a dismiss ✕. */
  onDismiss?: () => void;
}

/**
 * Inline contextual banner (stale-application warning, guardrail notice, etc).
 * @startingPoint section="Feedback" subtitle="Inline contextual message" viewport="360x100"
 */
export function Banner(props: BannerProps): JSX.Element;
