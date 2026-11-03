<script lang="ts">
	import { resolve } from '$app/paths';
	import { BarChart, LineChart } from 'layerchart';
	import BenchLine from '$lib/components/BenchLine.svelte';
	import PeerBars from '$lib/components/PeerBars.svelte';
	import {
		benchmarks,
		changesAt,
		commits,
		describeMachine,
		formatChange,
		machines,
		METRICS,
		peerCharts,
		REPO_URL,
		series,
		summary,
		trend,
		withLatestToy,
		type MetricKey
	} from '$lib/bench';

	let { data } = $props();

	const allMachines = $derived(machines(data.records));
	let machineChoice = $state<string>();
	const machineId = $derived(machineChoice ?? allMachines[0]?.id);
	const machine = $derived(allMachines.find((m) => m.id === machineId));
	const records = $derived(data.records.filter((r) => r.machine.id === machineId));

	let metricKey = $state<MetricKey>('instructions');
	const metric = $derived(METRICS.find((m) => m.key === metricKey)!);
	let xMode = $state<'commit' | 'date'>('commit');

	const history = $derived(commits(records));
	let selectedChoice = $state<string>();
	const selected = $derived(history.find((c) => c.sha === selectedChoice) ?? history.at(-1));

	const groups = $derived(
		(['runtime', 'compiler'] as const).map((kind) => ({
			kind,
			names: benchmarks(records).filter((b) => b.kind === kind).map((b) => b.name)
		}))
	);
	const rows = $derived(summary(records, metricKey));
	const changes = $derived(selected ? changesAt(records, selected.sha, metricKey) : []);
	const select = (sha: string) => (selectedChoice = sha);
	const index = (v: number) => v.toFixed(1);

	const PEER_METRICS = METRICS.filter((m) => m.key !== 'instructions');
	let peerMetricKey = $state<MetricKey>('wall_median_s');
	const peerMetric = $derived(PEER_METRICS.find((m) => m.key === peerMetricKey)!);
	let peerLog = $state(false);
	const latest = $derived(data.peers ? withLatestToy(data.peers, data.records) : undefined);
	const peerRows = $derived(latest ? peerCharts(latest.run, peerMetricKey) : []);

	// Lower is better for every metric, so a rise is the regression colour.
	const tone = (pct: number | undefined) => (pct === undefined || Math.abs(pct) < 0.05 ? '' : pct > 0 ? 'worse' : 'better');
</script>

<svelte:head>
	<title>Benchmarks — toy</title>
	<meta name="description" content="The speed of toy over time: runtime and compiler benchmarks per commit on main." />
</svelte:head>

<div class="bench-page mx-auto min-h-screen max-w-6xl border-x px-4 pb-24 pt-20 sm:px-10 md:px-12" style="border-color: var(--border)">
	<a href={resolve('/')} class="link text-[0.82rem]">← toy</a>
	<h1 class="mt-8 text-4xl">Benchmarks</h1>
	<p class="mt-3 max-w-[60ch] text-base leading-snug" style="color: var(--fg-muted)">
		How fast toy runs programs and compiles them, commit by commit on <code class="code">main</code>. Each point is one
		manual <code class="code">mise run bench</code> on one machine; numbers from different machines are not comparable.
	</p>

	{#if data.records.length === 0}
		<p class="mt-12 rounded-lg border p-6 text-sm" style="border-color: var(--border); background: var(--code-bg)" data-testid="bench-empty">
			No benchmark history yet. On <code class="code">main</code>, with a clean tree, run
			<code class="code">mise run bench</code> and commit <code class="code">bench/history.jsonl</code>.
		</p>
	{:else}
		<!-- The wrapper ends the sticky controls' reach with the history: they do not drive the peer view. -->
		<div>
		<div class="sticky top-0 z-10 mt-10 flex flex-wrap items-center gap-x-6 gap-y-3 border-b py-3 text-[0.8rem]" style="border-color: var(--border); background: var(--bg)">
			<div class="seg" role="group" aria-label="Metric">
				{#each METRICS as m (m.key)}
					<button type="button" aria-pressed={metricKey === m.key} onclick={() => (metricKey = m.key)}>{m.label}</button>
				{/each}
			</div>
			<div class="seg" role="group" aria-label="X axis">
				<button type="button" aria-pressed={xMode === 'commit'} onclick={() => (xMode = 'commit')}>By commit</button>
				<button type="button" aria-pressed={xMode === 'date'} onclick={() => (xMode = 'date')}>By date</button>
			</div>
			<label class="flex min-w-0 items-center gap-2">
				<span style="color: var(--fg-muted)">Machine</span>
				<select bind:value={() => machineId, (v) => (machineChoice = v)} class="min-w-0 max-w-full truncate rounded border px-2 py-1" style="border-color: var(--border); background: var(--bg-elev)">
					{#each allMachines as m (m.id)}
						<option value={m.id}>{m.chip} · {m.id}</option>
					{/each}
				</select>
			</label>
		</div>
		{#if machine}
			<p class="mt-2 text-[0.75rem]" style="color: var(--fg-muted)">{describeMachine(machine)}</p>
		{/if}

		<h2 class="section">Overall trend</h2>
		<p class="note">Geometric mean of each benchmark's {metric.label.toLowerCase()} from commit to commit, chained and indexed to 100 at the first record. Lower is better.</p>
		<div class="grid gap-6 md:grid-cols-2">
			{#each groups as g (g.kind)}
				{#if g.names.length}
					<figure data-trend={g.kind}>
						<figcaption class="caption">{g.kind} benchmarks</figcaption>
						<BenchLine points={trend(records, g.kind, metricKey)} {xMode} format={index} selected={selected?.sha} onselect={select} />
					</figure>
				{/if}
			{/each}
		</div>

		<h2 class="section">Summary</h2>
		<div class="overflow-x-auto">
			<table class="w-full text-left text-[0.8rem]" data-testid="bench-summary">
				<thead style="color: var(--fg-muted)">
					<tr>
						<th class="py-2 pr-4 font-normal">Benchmark</th>
						<th class="py-2 pr-4 text-right font-normal">Latest</th>
						<th class="py-2 pr-4 text-right font-normal">vs previous</th>
						<th class="py-2 pr-4 text-right font-normal">vs first</th>
						<th class="py-2 font-normal">Trend</th>
					</tr>
				</thead>
				<tbody>
					{#each rows as r (r.name)}
						<tr class="border-t" style="border-color: var(--border)">
							<td class="py-2 pr-4 font-mono">{r.name}</td>
							<td class="py-2 pr-4 text-right font-mono">{r.latest === undefined ? '–' : metric.format(r.latest)}</td>
							<td class="py-2 pr-4 text-right font-mono {tone(r.fromPrevious)}">{formatChange(r.fromPrevious)}</td>
							<td class="py-2 pr-4 text-right font-mono {tone(r.fromFirst)}">{formatChange(r.fromFirst)}</td>
							<td class="py-1">
								<div class="h-7 w-28">
									<LineChart data={r.points} x="index" y="value" yBaseline={null} axis={false} grid={false} tooltipContext={false} highlight={false} padding={{ top: 3, bottom: 3, left: 2, right: 2 }} />
								</div>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>

		<h2 class="section">Change per commit</h2>
		{#if selected}
			<p class="note" data-testid="bench-selected">
				<a class="link font-mono" href="{REPO_URL}/commit/{selected.sha}">{selected.sha.slice(0, 7)}</a>
				{selected.subject} · {selected.date.toISOString().slice(0, 10)}. Click a point in any chart to pick another commit.
			</p>
			{#if changes.length}
				<div class="h-48">
					<BarChart
						data={changes}
						x="name"
						xDomain={changes.map((c) => c.name)}
						series={[
							{ key: 'worse', value: 'pct', data: changes.filter((c) => c.pct > 0), color: 'var(--bench-worse)' },
							{ key: 'better', value: 'pct', data: changes.filter((c) => c.pct <= 0), color: 'var(--bench-better)' }
						]}
						padding={{ top: 8, right: 8, bottom: 22, left: 48 }}
						props={{ yAxis: { format: (v: number) => `${v}%`, ticks: 4 }, bars: { stroke: 'none' } }}
					/>
				</div>
			{:else}
				<p class="note">No earlier record to compare with.</p>
			{/if}
		{/if}

		{#each groups as g (g.kind)}
			{#if g.names.length}
				<h2 class="section">{g.kind} · {metric.label.toLowerCase()}</h2>
				<div class="grid gap-x-8 gap-y-10 md:grid-cols-2">
					{#each g.names as name (name)}
						<figure data-bench={name}>
							<figcaption class="caption font-mono">{name}</figcaption>
							<BenchLine points={series(records, name, metricKey)} {xMode} format={metric.format} selected={selected?.sha} onselect={select} />
						</figure>
					{/each}
				</div>
			{/if}
		{/each}
		</div>
	{/if}

	{#if data.peers && latest}
		{@const run = data.peers}
		<section data-testid="peers">
			<h2 class="section">Against other languages</h2>
			<p class="caveat note" role="note">
				Take these with a pinch of salt. They are a rough indication from one run of the suite on one machine, not a
				ranking: each program is small and written by us. Toy's bars track the latest bench record on
				<code class="code">main</code>, so they can come from a later session than the other languages.
			</p>
			<p class="note">
				The same algorithm in each language, single-threaded, standard library only, each printing the same checksum. Toy
				leads each chart. Sources:
				<a class="link" href="{REPO_URL}/tree/main/bench/peers">bench/peers</a>.
			</p>
			<dl class="peer-meta text-[0.75rem]" data-testid="peers-meta">
				<dt>Machine</dt>
				<dd>{describeMachine(run.machine)}, {run.machine.power}, load {run.machine.load_avg_1m}</dd>
				<dt>Peer run</dt>
				<dd>{run.date.slice(0, 10)}, median of {run.runs} runs</dd>
				<dt>Toy bars</dt>
				<dd data-testid="peers-toy">
					{#if latest.toy}
						<a class="link font-mono" href="{REPO_URL}/commit/{latest.toy.sha}">{latest.toy.sha.slice(0, 7)}</a>, {latest.toy.date}, latest
						<code class="code">main</code> record{#if latest.fallback.length}; {latest.fallback.join(', ')} from the peer run's
							<a class="link font-mono" href="{REPO_URL}/commit/{run.toy_commit}">{run.toy_commit.slice(0, 7)}</a>{run.toy_dirty ? ' (dirty tree)' : ''}{/if}
					{:else}
						<a class="link font-mono" href="{REPO_URL}/commit/{run.toy_commit}">{run.toy_commit.slice(0, 7)}</a>{run.toy_dirty ? ' (dirty tree)' : ''},
						{run.date.slice(0, 10)}, from the peer run (no bench record on this machine)
					{/if}
				</dd>
				<dt>Toolchains</dt>
				<dd>
					<ul>
						{#each Object.entries(run.toolchains) as [lang, t] (lang)}
							<li><span class="font-mono">{lang}</span>: {t.version} · <code class="code">{t.flags}</code></li>
						{/each}
					</ul>
				</dd>
			</dl>
			<div class="mt-6 flex flex-wrap items-center gap-x-6 gap-y-3 text-[0.8rem]">
				<div class="seg" role="group" aria-label="Peer metric">
					{#each PEER_METRICS as m (m.key)}
						<button type="button" aria-pressed={peerMetricKey === m.key} onclick={() => (peerMetricKey = m.key)}>{m.label}</button>
					{/each}
				</div>
				<div class="seg" role="group" aria-label="Peer scale">
					<button type="button" aria-pressed={!peerLog} onclick={() => (peerLog = false)}>Linear</button>
					<button type="button" aria-pressed={peerLog} onclick={() => (peerLog = true)}>Log</button>
				</div>
			</div>
			<div class="mt-6 grid gap-x-8 gap-y-10 md:grid-cols-2">
				{#each peerRows as c (c.name)}
					<figure data-peer={c.name}>
						<figcaption class="caption font-mono">{c.name}</figcaption>
						<PeerBars bars={c.bars} metric={peerMetricKey} format={peerMetric.format} log={peerLog} toolchains={run.toolchains} />
						<p class="sources">
							{#each c.bars as b (b.lang)}
								<a class="link" href="{REPO_URL}/blob/main/{b.result.source}">{b.lang}</a>
							{/each}
						</p>
					</figure>
				{/each}
			</div>
		</section>
	{/if}
</div>

<style>
	div :global(.lc-root-container),
	:global(.lc-tooltip-root) {
		--color-primary: var(--toy-teal);
		--color-surface-100: var(--bg-elev);
		--color-surface-200: var(--code-bg);
		--color-surface-300: var(--border);
		--color-surface-content: var(--fg);
	}
	.bench-page {
		--bench-worse: var(--toy-red);
		--bench-better: var(--tok-fn);
		--peer-bar: var(--fg-muted);
	}
	.caveat {
		border-left: 3px solid var(--toy-red);
		padding-left: 0.75rem;
		color: var(--fg);
	}
	.peer-meta {
		display: grid;
		grid-template-columns: max-content minmax(0, 1fr);
		gap: 0.25rem 1rem;
		color: var(--fg-muted);
	}
	.peer-meta dd {
		min-width: 0;
		overflow-wrap: anywhere;
	}
	.peer-meta code {
		white-space: normal;
	}
	.sources {
		display: flex;
		flex-wrap: wrap;
		gap: 0.75rem;
		margin-top: 0.25rem;
		font-size: 0.75rem;
	}
	.section {
		margin-top: 3.5rem;
		margin-bottom: 0.75rem;
		font-size: 1.5rem;
	}
	.note {
		margin-bottom: 1rem;
		max-width: 70ch;
		font-size: 0.8rem;
		color: var(--fg-muted);
	}
	.caption {
		margin-bottom: 0.25rem;
		font-size: 0.8rem;
	}
	.worse {
		color: var(--bench-worse);
	}
	.better {
		color: var(--bench-better);
	}
	.seg {
		display: inline-flex;
		overflow: hidden;
		border: 1px solid var(--border);
		border-radius: 0.4rem;
	}
	.seg button {
		padding: 0.25rem 0.7rem;
	}
	.seg button + button {
		border-left: 1px solid var(--border);
	}
	.seg button[aria-pressed='true'] {
		background: var(--fg);
		color: var(--bg);
	}
</style>
