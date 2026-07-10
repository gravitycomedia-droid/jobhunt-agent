Base job card — logo, title, company, location, source chip, plus salary and posted date. Use directly for Jobs List and Shortlist rows; extend for Matches.

```jsx
<JobCard title="Senior Product Designer" company="Northwind"
         location="San Francisco · Remote" source="LinkedIn"
         salary="$145K–$180K" postedAt="2 days ago"
         onBookmark={toggle} bookmarked />
```

- `trailing` replaces the top-right slot — MatchCard passes a `<ScoreRing>` there.
- `children` renders below the meta row — MatchCard passes strength/gap chips + verdict pill.
- Salary + posted date are optional; surface them now that the API already returns them.
