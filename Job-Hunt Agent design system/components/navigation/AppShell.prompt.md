Structural frame for every screen — top app-bar, scrollable content region, and the 5-destination bottom nav. Nothing else composes without it.

```jsx
<AppShell active="matches" onNavigate={setRoute} title="Matches"
          trailing={<Icon name="bell" />}>
  {/* screen content */}
</AppShell>
```

- Default destinations: Home · Jobs · Matches · Track (applications) · Profile.
- Active tab shows a soft-brand pill behind its icon + brand-colored label.
- `showHeader={false}` when a screen supplies its own hero header (e.g. Home greeting).
- Fills 100% of its parent — preview inside an iOS/Android frame at ~390×780.
