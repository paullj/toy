import { describe, expect, it } from 'vitest';
import { changesAt, commits, machines, parseHistory, series, summary, trend, type BenchRecord } from './bench';

const machine = (id: string) => ({
	id,
	chip: 'Apple M2 Pro',
	model: 'Mac14,9',
	p_cores: 6,
	e_cores: 4,
	ram_bytes: 32 * 2 ** 30,
	macos: '27.0',
	zig: '0.16.0',
	power: 'ac',
	load_avg_1m: 1
});

function rec(sha: string, name: string, instructions: number, opts: { kind?: string; id?: string; date?: string } = {}) {
	return JSON.stringify({
		sha,
		subject: `commit ${sha}`,
		commit_date: opts.date ?? '2026-11-01T00:00:00Z',
		run_date: '2026-11-01T00:00:00Z',
		name,
		kind: opts.kind ?? 'runtime',
		runs: 5,
		metrics: { instructions, cycles: 1, max_rss_bytes: 1, peak_footprint_bytes: 1, wall_median_s: 1, wall_mean_s: 1, wall_stddev_s: 0, user_s: 1, sys_s: 0 },
		machine: machine(opts.id ?? 'm1')
	});
}

const lines = (...ls: string[]) => parseHistory(ls.join('\n') + '\n');

describe('parseHistory', () => {
	it('reads an empty file as no records', () => {
		expect(parseHistory('')).toEqual([]);
		expect(parseHistory('\n')).toEqual([]);
	});

	it('reads one record per line', () => {
		const rs = lines(rec('a', 'loops', 10), rec('a', 'alloc', 20));
		expect(rs.map((r) => [r.sha, r.name, r.metrics.instructions])).toEqual([
			['a', 'loops', 10],
			['a', 'alloc', 20]
		]);
		expect(rs[0].machine.chip).toBe('Apple M2 Pro');
	});

	it('names the line of a bad record', () => {
		expect(() => parseHistory(rec('a', 'loops', 1) + '\n{oops')).toThrow('history line 2: not JSON');
		expect(() => parseHistory('{"sha":"a"}')).toThrow('history line 1: no name');
	});
});

describe('derived views', () => {
	const rs: BenchRecord[] = lines(
		rec('a', 'loops', 100),
		rec('a', 'alloc', 400),
		rec('b', 'loops', 110),
		rec('b', 'alloc', 100),
		rec('c', 'loops', 121),
		rec('c', 'check', 50, { kind: 'compiler' }),
		rec('c', 'loops', 999, { id: 'm2' })
	);
	const m1 = rs.filter((r) => r.machine.id === 'm1');

	it('orders commits as the file first records them', () => {
		expect(commits(m1).map((c) => [c.sha, c.index])).toEqual([
			['a', 0],
			['b', 1],
			['c', 2]
		]);
	});

	it('orders commits by commit date when a machine records an older commit later', () => {
		const late = lines(
			rec('newer', 'loops', 1, { date: '2026-11-05T00:00:00Z' }),
			rec('older', 'loops', 1, { date: '2026-11-01T00:00:00Z', id: 'm2' })
		);
		expect(commits(late).map((c) => [c.sha, c.index])).toEqual([
			['older', 0],
			['newer', 1]
		]);
	});

	it('lists machines, the most recorded first', () => {
		expect(machines(rs).map((m) => [m.id, m.count])).toEqual([
			['m1', 6],
			['m2', 1]
		]);
	});

	it('gives a benchmark one point per commit, a re-run replacing the earlier one', () => {
		const again = [...m1, ...lines(rec('b', 'loops', 115))];
		expect(series(again, 'loops', 'instructions').map((p) => [p.sha, p.index, p.value])).toEqual([
			['a', 0, 100],
			['b', 1, 115],
			['c', 2, 121]
		]);
	});

	it('indexes the geometric mean to 100 at the first record', () => {
		const t = trend(m1, 'runtime', 'instructions');
		expect(t.map((p) => p.sha)).toEqual(['a', 'b', 'c']);
		expect(t[0].value).toBeCloseTo(100);
		// loops 1.1x, alloc 0.25x: sqrt(1.1 * 0.25) = 0.5244
		expect(t[1].value).toBeCloseTo(52.44, 1);
		// Only loops ran at c: it moved 1.1x from b.
		expect(t[2].value).toBeCloseTo(52.44 * 1.1, 1);
		expect(trend(m1, 'compiler', 'instructions').map((p) => [p.sha, p.value])).toEqual([['c', 100]]);
	});

	it('does not move the trend when a benchmark is added or dropped', () => {
		const t = trend(
			lines(rec('a', 'loops', 100), rec('b', 'loops', 50), rec('c', 'loops', 50), rec('c', 'fannkuch', 1000), rec('d', 'fannkuch', 1000)),
			'runtime',
			'instructions'
		);
		expect(t.map((p) => [p.sha, Math.round(p.value * 10) / 10])).toEqual([
			['a', 100],
			['b', 50],
			['c', 50],
			['d', 50]
		]);
	});

	it('summarises the latest value and its changes', () => {
		const loops = summary(m1, 'instructions').find((s) => s.name === 'loops')!;
		expect(loops.latest).toBe(121);
		expect(loops.fromPrevious).toBeCloseTo(10);
		expect(loops.fromFirst).toBeCloseTo(21);
		const check = summary(m1, 'instructions').find((s) => s.name === 'check')!;
		expect(check.fromPrevious).toBeUndefined();
		expect(check.fromFirst).toBeUndefined();
	});

	it('gives the change per benchmark at a commit', () => {
		expect(changesAt(m1, 'b', 'instructions')).toEqual([
			{ name: 'loops', kind: 'runtime', pct: expect.closeTo(10) },
			{ name: 'alloc', kind: 'runtime', pct: expect.closeTo(-75) }
		]);
		expect(changesAt(m1, 'a', 'instructions')).toEqual([]);
	});
});
