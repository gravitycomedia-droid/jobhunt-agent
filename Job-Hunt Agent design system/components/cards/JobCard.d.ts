import React from "react";

export interface JobCardProps extends Omit<React.HTMLAttributes<HTMLDivElement>, "title"> {
  /** Job title (clamped to 2 lines). */
  title: string;
  /** Company name. */
  company: string;
  /** Location string, e.g. "San Francisco · Remote". */
  location?: string;
  /** Source name shown as an info chip, e.g. "LinkedIn". */
  source?: string;
  /** Compensation string, rendered in mono, e.g. "$145K–$180K". */
  salary?: string;
  /** Posted-date string, e.g. "2 days ago". */
  postedAt?: string;
  /** Company logo URL; falls back to a brand-tinted initial tile. */
  logoUrl?: string;
  /** Bookmarked state (fills the bookmark glyph). */
  bookmarked?: boolean;
  /** Bookmark toggle handler; when set the default trailing bookmark button renders. */
  onBookmark?: () => void;
  /** Card tap handler (makes the whole card a button). */
  onPress?: () => void;
  /** Replaces the top-right slot — pass a ScoreRing here for MatchCard. */
  trailing?: React.ReactNode;
  /** Extra content rendered below the meta row (chips, verdict, expandable body). */
  children?: React.ReactNode;
}

/**
 * Base job card: logo, title, company, location, source chip, plus optional
 * salary/posted date. The base component for Shortlist rows and MatchCard —
 * extend via `trailing` (score ring) and `children` (chips/verdict).
 *
 * @startingPoint section="Cards" subtitle="Title · company · source · salary" viewport="360x150"
 */
export function JobCard(props: JobCardProps): JSX.Element;
