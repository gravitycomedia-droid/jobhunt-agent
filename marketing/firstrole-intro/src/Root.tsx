import React from 'react';
import { Composition } from 'remotion';
import { FirstRoleIntro } from './FirstRoleIntro';
import { FPS, DURATION_IN_FRAMES, WIDTH, HEIGHT } from './content';

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="FirstRoleLinkedInIntro"
      component={FirstRoleIntro}
      durationInFrames={DURATION_IN_FRAMES}
      fps={FPS}
      width={WIDTH}
      height={HEIGHT}
    />
  );
};
