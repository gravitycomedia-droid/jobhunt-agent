import React from "react";
import { IconName } from "../icons/Icon";

export interface Destination {
  /** Stable route key, e.g. "home" | "jobs" | "matches" | "applications" | "profile". */
  key: string;
  /** Short label shown under the icon (≤10 chars keeps the 5-up bar tidy). */
  label: string;
  /** Glyph name from the Icon set. */
  icon: IconName;
}

export interface AppShellProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Active destination key. */
  active?: string;
  /** Called with the tapped destination key. */
  onNavigate?: (key: string) => void;
  /** Override the 5 default destinations (Home / Jobs / Matches / Track / Profile). */
  destinations?: Destination[];
  /** Top app-bar title. */
  title?: string;
  /** Right-aligned header slot (icon buttons, etc). */
  trailing?: React.ReactNode;
  /** Hide the top app-bar (e.g. Home renders its own hero header). Default true. */
  showHeader?: boolean;
  /** Screen content. */
  children?: React.ReactNode;
}

/**
 * Portrait-first app frame: top app-bar + scrollable content + 5-destination
 * bottom nav. Fills its parent — wrap in a device frame to preview.
 *
 * @startingPoint section="Navigation" subtitle="App frame + 5-tab bottom nav" viewport="390x780"
 */
export function AppShell(props: AppShellProps): JSX.Element;
