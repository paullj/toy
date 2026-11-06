export type Machine = {
	id: string;
	chip: string;
	model: string;
	p_cores: number;
	e_cores: number;
	ram_bytes: number;
	macos: string;
	zig: string;
	power: string;
	load_avg_1m: number;
};

export type Metrics = {
	instructions: number;
	cycles: number;
	max_rss_bytes: number;
	peak_footprint_bytes: number;
	wall_median_s: number;
	wall_mean_s: number;
	wall_stddev_s: number;
	wall_min_s: number;
	wall_max_s: number;
	user_s: number;
	sys_s: number;
};

export type BenchRecord = {
	sha: string;
	subject: string;
	commit_date: string;
	run_date: string;
	name: string;
	kind: 'runtime' | 'compiler';
	runs: number;
	/** A compiler benchmark's project lines; absent before #190 and on runtime records. */
	lines?: number | null;
	metrics: Metrics;
	checksum?: string | null;
	checksum_ok?: boolean;
	machine: Machine;
};

export type MetricKey = 'instructions' | 'wall_median_s' | 'peak_footprint_bytes';

export const METRICS: { key: MetricKey; label: string; format: (v: number) => string }[] = [
	{ key: 'instructions', label: 'Instructions', format: (v) => `${(v / 1e6).toFixed(1)}M` },
	{ key: 'wall_median_s', label: 'Wall time', format: (v) => `${(v * 1000).toFixed(1)} ms` },
	{ key: 'peak_footprint_bytes', label: 'Peak memory', format: (v) => `${(v / 1048576).toFixed(1)} MiB` }
];

export const REPO_URL = 'https://github.com/paullj/toy';

/** One record per line; blank lines are allowed so a trailing newline or an empty file parses. */
export function parseHistory(text: string): BenchRecord[] {
	const records: BenchRecord[] = [];
	text.split('\n').forEach((line, i) => {
		if (line.trim() === '') return;
		let r: BenchRecord;
		try {
			r = JSON.parse(line);
		} catch {
			throw new Error(`history line ${i + 1}: not JSON`);
		}
		for (const field of ['sha', 'name', 'kind', 'commit_date', 'metrics', 'machine'] as const) {
			if (r[field] === undefined) throw new Error(`history line ${i + 1}: no ${field}`);
		}
		records.push(r);
	});
	return records;
}

export function machines(records: BenchRecord[]): (Machine & { count: number })[] {
	const byId = new Map<string, Machine & { count: number }>();
	for (const r of records) {
		const m = byId.get(r.machine.id);
		if (m) m.count++;
		else byId.set(r.machine.id, { ...r.machine, count: 1 });
	}
	return [...byId.values()].sort((a, b) => b.count - a.count);
}

export function describeMachine(m: Machine): string {
	const ram = Math.round(m.ram_bytes / 2 ** 30);
	return `${m.chip} (${m.model}), ${m.p_cores}P+${m.e_cores}E cores, ${ram} GB, macOS ${m.macos}, zig ${m.zig}`;
}

export type Commit = { sha: string; subject: string; date: Date; index: number };

/**
 * Commits in main's order. The file's order is not enough: a machine whose main lags can
 * record an older commit after a newer one. Rebase merges give main ascending commit dates,
 * so those decide, and the file's order breaks ties.
 */
export function commits(records: BenchRecord[]): Commit[] {
	const seen = new Map<string, Commit>();
	for (const r of records) {
		if (!seen.has(r.sha)) seen.set(r.sha, { sha: r.sha, subject: r.subject, date: new Date(r.commit_date), index: seen.size });
	}
	return [...seen.values()]
		.sort((a, b) => a.date.getTime() - b.date.getTime() || a.index - b.index)
		.map((c, index) => ({ ...c, index }));
}

export type Point = Commit & { value: number; record: BenchRecord };

/** A re-run of a commit replaces its earlier record. */
export function series(records: BenchRecord[], name: string, metric: MetricKey): Point[] {
	const order = new Map(commits(records).map((c) => [c.sha, c]));
	const latest = new Map<string, BenchRecord>();
	for (const r of records) if (r.name === name) latest.set(r.sha, r);
	return [...latest.values()]
		.map((r) => ({ ...order.get(r.sha)!, value: r.metrics[metric], record: r }))
		.sort((a, b) => a.index - b.index);
}

export function benchmarks(records: BenchRecord[]): { name: string; kind: BenchRecord['kind'] }[] {
	const seen = new Map<string, BenchRecord['kind']>();
	for (const r of records) if (!seen.has(r.name)) seen.set(r.name, r.kind);
	return [...seen].map(([name, kind]) => ({ name, kind }));
}

/**
 * An index of the benchmarks of `kind`, 100 at the first commit. Each commit multiplies the
 * index of the commit before by the geometric mean of the benchmarks' ratios between the
 * two, over the benchmarks recorded at both. A geometric mean keeps one long benchmark from
 * outweighing the rest, and the chaining keeps an added or dropped benchmark from moving
 * the index when nothing changed.
 */
export function trend(records: BenchRecord[], kind: BenchRecord['kind'], metric: MetricKey): (Commit & { value: number })[] {
	const names = benchmarks(records).filter((b) => b.kind === kind).map((b) => b.name);
	const perBench = names.map((n) => new Map(series(records, n, metric).map((p) => [p.sha, p.value])));
	const out: (Commit & { value: number })[] = [];
	for (const c of commits(records)) {
		const here = perBench.filter((vals) => vals.has(c.sha));
		if (here.length === 0) continue;
		const prev = out.at(-1);
		if (!prev) {
			out.push({ ...c, value: 100 });
			continue;
		}
		const ratios = here.flatMap((vals) => {
			const before = vals.get(prev.sha);
			return before && before > 0 ? [vals.get(c.sha)! / before] : [];
		});
		const step = ratios.length === 0 ? 1 : Math.exp(ratios.reduce((s, r) => s + Math.log(r), 0) / ratios.length);
		out.push({ ...c, value: prev.value * step });
	}
	return out;
}

export const change = (from: number | undefined, to: number | undefined) =>
	from === undefined || to === undefined || from === 0 ? undefined : (to / from - 1) * 100;

export const linesPerSecond = (r: BenchRecord | undefined) =>
	r?.lines ? r.lines / r.metrics.wall_median_s : undefined;

export const formatLinesPerSecond = (v: number | undefined) => (v === undefined ? '–' : `${(v / 1000).toFixed(1)}k`);

export function summary(records: BenchRecord[], metric: MetricKey) {
	return benchmarks(records).map(({ name, kind }) => {
		const pts = series(records, name, metric);
		const last = pts.at(-1);
		return {
			name,
			kind,
			latest: last?.value,
			linesPerSecond: linesPerSecond(last?.record),
			fromPrevious: change(pts.at(-2)?.value, last?.value),
			fromFirst: pts.length > 1 ? change(pts[0].value, last?.value) : undefined,
			points: pts
		};
	});
}

/** Each benchmark's change at `sha` from its record at the commit before. */
export function changesAt(records: BenchRecord[], sha: string, metric: MetricKey) {
	return benchmarks(records).flatMap(({ name, kind }) => {
		const pts = series(records, name, metric);
		const i = pts.findIndex((p) => p.sha === sha);
		const pct = i > 0 ? change(pts[i - 1].value, pts[i].value) : undefined;
		return pct === undefined ? [] : [{ name, kind, pct }];
	});
}

export const formatChange = (pct: number | undefined) =>
	pct === undefined ? '–' : `${pct > 0 ? '+' : ''}${pct.toFixed(1)}%`;

export type PeerResult = {
	name: string;
	lang: string;
	source: string;
	metrics: Metrics;
	checksum: string;
	checksum_ok: boolean;
};

export type PeerRun = {
	date: string;
	toy_commit: string;
	toy_dirty: boolean;
	runs: number;
	machine: Machine;
	toolchains: Record<string, { version: string; flags: string }>;
	results: PeerResult[];
};

export function parsePeers(text: string): PeerRun {
	let run: PeerRun;
	try {
		run = JSON.parse(text);
	} catch {
		throw new Error('peers.json: not JSON');
	}
	for (const field of ['date', 'toy_commit', 'machine', 'toolchains', 'results'] as const) {
		if (run[field] === undefined) throw new Error(`peers.json: no ${field}`);
	}
	run.results.forEach((r, i) => {
		for (const field of ['name', 'lang', 'source', 'metrics'] as const) {
			if (r[field] === undefined) throw new Error(`peers.json: result ${i + 1} has no ${field}`);
		}
	});
	return run;
}

// Interpreted and JIT runtimes sit too far from the compiled peers to say much here.
export const HIDDEN_PEERS = ['js', 'python'];

/** Also drops the toy row of a benchmark left with no peer: a lone bar compares nothing. */
export function withoutHiddenPeers(run: PeerRun): PeerRun {
	const shown = (lang: string) => !HIDDEN_PEERS.includes(lang);
	const peered = new Set(run.results.filter((r) => r.lang !== 'toy' && shown(r.lang)).map((r) => r.name));
	return {
		...run,
		toolchains: Object.fromEntries(Object.entries(run.toolchains).filter(([lang]) => shown(lang))),
		results: run.results.filter((r) => shown(r.lang) && peered.has(r.name))
	};
}

export type LatestToy = {
	run: PeerRun;
	/** The newest commit among the history records that replaced toy rows. */
	toy: { sha: string; date: string } | undefined;
	/** Benchmarks whose toy bar still comes from the peers run. */
	fallback: string[];
};

/**
 * Swaps each toy row for the newest main record of the same benchmark on the peers run's
 * machine, so every `mise run bench` refreshes the comparison without rerunning the peers.
 */
export function withLatestToy(run: PeerRun, records: BenchRecord[]): LatestToy {
	const mine = records.filter((r) => r.machine.id === run.machine.id);
	let toy: Point | undefined;
	const fallback: string[] = [];
	const results = run.results.map((r) => {
		if (r.lang !== 'toy') return r;
		const latest = series(mine, r.name, 'wall_median_s').at(-1);
		if (!latest) {
			fallback.push(r.name);
			return r;
		}
		if (!toy || latest.index > toy.index) toy = latest;
		const rec = latest.record;
		return { ...r, metrics: rec.metrics, checksum: rec.checksum ?? r.checksum, checksum_ok: rec.checksum_ok ?? true };
	});
	return {
		run: { ...run, results },
		toy: toy && { sha: toy.sha, date: (toy.record.run_date ?? toy.record.commit_date).slice(0, 10) },
		fallback
	};
}

export type PeerBar = { lang: string; value: number; vsToy: number | undefined; result: PeerResult };

/** Toy leads each chart so the eye has one fixed reference; the peers keep the runner's order. */
export function peerCharts(run: PeerRun, metric: MetricKey): { name: string; bars: PeerBar[] }[] {
	const byName = new Map<string, PeerResult[]>();
	for (const r of run.results) byName.set(r.name, [...(byName.get(r.name) ?? []), r]);
	return [...byName].map(([name, results]) => {
		const ordered = [...results.filter((r) => r.lang === 'toy'), ...results.filter((r) => r.lang !== 'toy')];
		const toy = results.find((r) => r.lang === 'toy')?.metrics[metric];
		return {
			name,
			bars: ordered.map((r) => ({
				lang: r.lang,
				value: r.metrics[metric],
				vsToy: toy ? r.metrics[metric] / toy : undefined,
				result: r
			}))
		};
	});
}

export function unpeered(records: BenchRecord[], charts: { name: string }[]): string[] {
	const charted = new Set(charts.map((c) => c.name));
	return benchmarks(records)
		.filter((b) => b.kind === 'runtime' && !charted.has(b.name))
		.map((b) => b.name);
}

const BETTER: Record<MetricKey, string> = {
	instructions: 'fewer instructions',
	wall_median_s: 'faster',
	peak_footprint_bytes: 'less memory'
};

const times = (x: number) => `${x.toFixed(x < 10 ? 2 : 0)}×`;

export function vsToyLabel(ratio: number | undefined, metric: MetricKey): string {
	if (ratio === undefined) return '';
	return ratio >= 1 ? `${times(ratio)} toy` : `${times(1 / ratio)} ${BETTER[metric]} than toy`;
}
