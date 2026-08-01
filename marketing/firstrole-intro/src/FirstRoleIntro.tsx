import React from 'react';
import { AbsoluteFill, Sequence } from 'remotion';
import { GradientBg } from './components/GradientBg';
import { Hook } from './scenes/Hook';
import { Problem } from './scenes/Problem';
import { Solution } from './scenes/Solution';
import { CTA } from './scenes/CTA';
import { TIMING } from './content';

export const FirstRoleIntro: React.FC = () => {
  return (
    <AbsoluteFill>
      <GradientBg />
      <Sequence from={TIMING.hook.from} durationInFrames={TIMING.hook.duration}>
        <Hook />
      </Sequence>
      <Sequence from={TIMING.problem.from} durationInFrames={TIMING.problem.duration}>
        <Problem />
      </Sequence>
      <Sequence from={TIMING.solution.from} durationInFrames={TIMING.solution.duration}>
        <Solution />
      </Sequence>
      <Sequence from={TIMING.cta.from} durationInFrames={TIMING.cta.duration}>
        <CTA />
      </Sequence>
    </AbsoluteFill>
  );
};
