import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { readPeers } from './peers';

describe('readPeers', () => {
	const dir = mkdtempSync(join(tmpdir(), 'peers-'));

	it('reads no run from a missing file, so the page hides the peer view', () => {
		expect(readPeers(join(dir, 'missing.json'))).toBeNull();
	});

	it('parses a present file and fails loudly on a broken one', () => {
		const ok = join(dir, 'ok.json');
		writeFileSync(ok, JSON.stringify({ date: 'd', toy_commit: 'c', machine: {}, toolchains: {}, results: [] }));
		expect(readPeers(ok)?.toy_commit).toBe('c');
		const bad = join(dir, 'bad.json');
		writeFileSync(bad, '{');
		expect(() => readPeers(bad)).toThrow('not JSON');
	});
});
