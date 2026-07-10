import React from "react";

export interface LoadingSkeletonProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Shape. Default "line". */
  variant?: "line" | "block" | "circle" | "card";
  /** Width (line/block). */
  width?: number | string;
  /** Height (line/block). */
  height?: number;
  /** Diameter for circle. Default 42. */
  size?: number;
  /** Number of lines for the "line" variant. Default 1. */
  count?: number;
}

/**
 * Shimmer placeholder for loading states. Needs the `jha-shimmer` keyframes
 * (see prompt) in the host page.
 * @startingPoint section="Feedback" subtitle="Loading placeholder" viewport="360x160"
 */
export function LoadingSkeleton(props: LoadingSkeletonProps): JSX.Element;
