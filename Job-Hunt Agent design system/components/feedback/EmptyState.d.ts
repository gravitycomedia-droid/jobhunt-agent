import React from "react";
import { IconName } from "../icons/Icon";

export interface EmptyStateProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Medallion glyph. Default "search". */
  icon?: IconName;
  /** Headline. */
  title?: string;
  /** Supporting message. */
  message?: string;
  /** Primary action label. */
  actionLabel?: string;
  /** Action handler. */
  onAction?: () => void;
}

/**
 * Zero-data pattern shared by Jobs, Shortlist, Matches, Applications, Activity Log.
 * @startingPoint section="Feedback" subtitle="Zero-data state" viewport="360x260"
 */
export function EmptyState(props: EmptyStateProps): JSX.Element;
