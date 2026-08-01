import React from 'react';
import { AbsoluteFill, Sequence } from 'remotion';
import { Wordmark } from '../components/Wordmark';
import { FeatureCallout } from '../components/FeatureCallout';
import { CONTENT } from '../content';

const LOGO_LEN = 45; // 1.5s reveal
const FEATURE_LEN = 55; // 3 features × 55 = 165, + LOGO_LEN = 210 (matches TIMING.solution.duration)

export const Solution: React.FC = () => {
  return (
    <AbsoluteFill>
      <Sequence from={0} durationInFrames={LOGO_LEN}>
        <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
          <Wordmark size={104} />
        </AbsoluteFill>
      </Sequence>
      {CONTENT.features.map((f, i) => (
        <Sequence
          key={f.label}
          from={LOGO_LEN + i * FEATURE_LEN}
          durationInFrames={FEATURE_LEN}
        >
          <FeatureCallout icon={f.icon} label={f.label} screenshot={f.screenshot} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
