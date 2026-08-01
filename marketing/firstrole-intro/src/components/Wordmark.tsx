import React from 'react';
import { useCurrentFrame, useVideoConfig, spring } from 'remotion';
import { COLORS, FONTS, CONTENT } from '../content';

// The FirstRole wordmark. No logo file yet, so this is a styled text mark —
// swap it for an <Img src={staticFile('logo.svg')} /> later if a real
// logo/icon shows up; the spring-in wrapper can stay the same.
export const Wordmark: React.FC<{ size?: number }> = ({ size = 96 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const scale = spring({
    frame,
    fps,
    config: { damping: 12, stiffness: 120, mass: 0.6 },
  });

  return (
    <div
      style={{
        transform: `scale(${scale})`,
        fontFamily: FONTS.display,
        fontWeight: 800,
        fontSize: size,
        letterSpacing: -2,
        display: 'flex',
      }}
    >
      <span style={{ color: COLORS.ink }}>First</span>
      <span style={{ color: COLORS.accentStrong }}>
        {CONTENT.brand.name.replace('First', '')}
      </span>
    </div>
  );
};
