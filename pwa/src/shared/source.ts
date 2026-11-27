// Where the app's data comes from.
//  - Production: the authenticated cloud projection (Phase 2 PR-05B + Phase 3
//    login). Until both exist the app shows the sign-in gate, never data.
//  - `vite --mode fixtures`: clearly labelled synthetic data for development
//    and screenshots. That branch is removed from production bundles
//    (import.meta.env.MODE is a build-time constant) and CI checks it.
import type { CloudState } from './cloud';
import { probe, readConfig } from './cloud';
import { type CommandChannel, offlineChannel } from './commands';
import type { Snapshot } from './model';

export type LoadState =
  | { kind: 'ready'; snapshot: Snapshot; fixtures: boolean }
  | { kind: 'signedOut'; cloud: CloudState };

export interface DataSource {
  load(): Promise<LoadState>;
  commands: CommandChannel;
}

export function cloudSource(env: Record<string, string | undefined>): DataSource {
  return {
    commands: offlineChannel,
    async load() {
      // No session store yet (Phase 3): always signed out.
      return { kind: 'signedOut', cloud: await probe(readConfig(env)) };
    },
  };
}

export async function createSource(app: 'personel' | 'yonetici'): Promise<DataSource> {
  if (import.meta.env.MODE === 'fixtures') {
    const { fixtureSource } = await import('../fixtures/source');
    return fixtureSource(app);
  }
  return cloudSource(import.meta.env as Record<string, string | undefined>);
}
