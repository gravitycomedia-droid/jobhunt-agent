import React from "react";

export interface ActivityLogItemProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Determines icon + tint. */
  kind?: "agent" | "match" | "applied" | "warning" | "rejected" | "info";
  /** Primary line. */
  title: string;
  /** Optional secondary detail line. */
  detail?: string;
  /** Right-aligned timestamp (mono), e.g. "2h ago". */
  timestamp?: string;
  /** Last item — hides the connecting rail. */
  last?: boolean;
}

/**
 * A single timeline entry for the Agent Activity Log.
 * @startingPoint section="Cards" subtitle="Activity timeline entry" viewport="360x100"
 */
export function ActivityLogItem(props: ActivityLogItemProps): JSX.Element;
