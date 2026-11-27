// Two installable apps from one codebase (spec V5.1 §20.1): APP=personel or
// APP=yonetici selects the entry, manifest and output folder. Each app is a
// separate origin on Cloudflare Pages, so storage and logout are isolated.
import { defineConfig, type Plugin } from 'vite';
import { cpSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));

const app = process.env.APP === 'yonetici' ? 'yonetici' : 'personel';

// Shared icons, service worker and headers are copied into each app; the
// per-app manifest comes from src/<app>/public.
const sharedPublic = (): Plugin => ({
  name: 'nohut-shared-public',
  closeBundle() {
    cpSync(resolve(here, 'public'), resolve(here, 'dist', app), {
      recursive: true,
    });
  },
});

export default defineConfig({
  root: resolve(here, 'src', app),
  publicDir: resolve(here, 'src', app, 'public'),
  plugins: [sharedPublic()],
  envDir: here,
  base: '/',
  build: {
    outDir: resolve(here, 'dist', app),
    emptyOutDir: true,
    target: 'es2022',
    sourcemap: false,
  },
  define: { __APP__: JSON.stringify(app) },
});
