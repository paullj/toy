import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseHistory } from '$lib/bench';
import { readPeers } from '$lib/server/peers';

// Read at build time (the page is prerendered). BENCH_HISTORY and BENCH_PEERS let the e2e
// tests build the page from fixtures instead of the real results.
export function load() {
	const path = resolve(process.env.BENCH_HISTORY ?? '../../bench/history.jsonl');
	return {
		records: parseHistory(readFileSync(path, 'utf8')),
		peers: readPeers(resolve(process.env.BENCH_PEERS ?? '../../bench/results/peers.json'))
	};
}
