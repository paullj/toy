import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseHistory } from '$lib/bench';

// Read at build time (the page is prerendered). BENCH_HISTORY lets the e2e tests build
// the page from a fixture instead of the real history.
export function load() {
	const path = resolve(process.env.BENCH_HISTORY ?? '../../bench/history.jsonl');
	return { records: parseHistory(readFileSync(path, 'utf8')) };
}
