import { defineConfig } from '@playwright/test';

// One explicit address: `localhost` can resolve to ::1 for the server and 127.0.0.1 for
// the readiness probe, and the probe then waits out the whole timeout.
const url = 'http://127.0.0.1:4173';

// `exec vite`, not `pnpm preview`: pnpm 12 exits on SIGTERM without stopping vite, and
// Playwright then waits forever on the orphan's open pipes.
export default defineConfig({
	testDir: 'e2e',
	webServer: {
		command: 'pnpm build && exec vite preview --host 127.0.0.1 --port 4173 --strictPort',
		url,
		timeout: 120_000,
		// The benchmarks page is built from fixtures, not the real (possibly empty) results.
		env: { BENCH_HISTORY: 'e2e/fixtures/history.jsonl', BENCH_PEERS: 'e2e/fixtures/peers.json' }
	},
	use: { baseURL: url }
});
