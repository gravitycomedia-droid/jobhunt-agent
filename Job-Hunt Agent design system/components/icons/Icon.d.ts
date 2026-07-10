import React from "react";

export type IconName =
  | "home" | "briefcase" | "target" | "columns" | "user"
  | "mapPin" | "building" | "externalLink" | "search" | "bell" | "bookmark"
  | "check" | "x" | "minus" | "arrowUpRight" | "alertTriangle" | "info"
  | "chevronDown" | "chevronRight" | "plus" | "clock" | "bot" | "upload" | "fileText";

export interface IconProps extends React.SVGProps<SVGSVGElement> {
  /** Glyph name from the curated Lucide-style set. */
  name: IconName;
  /** Pixel size (square). Default 20. */
  size?: number;
  /** Stroke width. Default 2. */
  strokeWidth?: number;
  /** Overrides currentColor. */
  color?: string;
}

/** Line-icon primitive. Inherits currentColor by default. */
export function Icon(props: IconProps): JSX.Element;
