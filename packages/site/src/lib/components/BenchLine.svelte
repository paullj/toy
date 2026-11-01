<script lang="ts">
	import { LineChart, Tooltip } from 'layerchart';
	import { describeMachine, REPO_URL, type BenchRecord, type Commit } from '$lib/bench';

	type Row = Commit & { value: number; record?: BenchRecord };

	let {
		points,
		xMode,
		format,
		selected,
		onselect,
		height = 180
	}: {
		points: Row[];
		xMode: 'commit' | 'date';
		format: (v: number) => string;
		selected?: string;
		onselect: (sha: string) => void;
		height?: number;
	} = $props();

	const short = (sha: string) => sha.slice(0, 7);
	const day = (d: Date) => d.toISOString().slice(0, 10);
	const at = $derived(points.find((p) => p.sha === selected));
	const ms = (s: number) => `${(s * 1000).toFixed(1)} ms`;
</script>

<div style="height: {height}px">
	<LineChart
		data={points}
		x={xMode === 'commit' ? 'index' : 'date'}
		y="value"
		yBaseline={null}
		yNice
		padding={{ top: 8, right: 12, bottom: 22, left: 64 }}
		points={{ r: 3 }}
		props={{
			yAxis: { format, ticks: 4 },
			xAxis: { format: xMode === 'commit' ? (i: number) => (Number.isInteger(i) ? `#${i + 1}` : '') : day, ticks: 5 }
		}}
		annotations={at ? [{ type: 'line', x: xMode === 'commit' ? at.index : at.date, props: { line: { class: 'bench-selected' } } }] : []}
		onTooltipClick={(e, { data }) => {
			const sha = (data as Row).sha;
			if (e.metaKey || e.ctrlKey) window.open(`${REPO_URL}/commit/${sha}`, '_blank', 'noopener');
			else onselect(sha);
		}}
	>
		{#snippet tooltip({ context })}
			<Tooltip.Root {context}>
				{#snippet children({ data })}
					{@const p = data as Row}
					<div class="bench-tip">
						<div><code>{short(p.sha)}</code> {p.subject}</div>
						<div class="muted">{day(p.date)} · commit #{p.index + 1}</div>
						<div class="value">{format(p.value)}</div>
						{#if p.record}
							{@const m = p.record.metrics}
							<div class="muted">
								{(m.cycles / 1e6).toFixed(1)}M cycles · user {ms(m.user_s)} · sys {ms(m.sys_s)} · ± {ms(m.wall_stddev_s)}
							</div>
							<div class="muted">{describeMachine(p.record.machine)}, {p.record.machine.power}</div>
						{/if}
						<div class="muted">click: compare this commit · ⌘/ctrl-click: open it on GitHub</div>
					</div>
				{/snippet}
			</Tooltip.Root>
		{/snippet}
	</LineChart>
</div>

<style>
	.bench-tip {
		max-width: 22rem;
		font-size: 0.75rem;
		line-height: 1.4;
	}
	.bench-tip .muted {
		color: var(--fg-muted);
	}
	.bench-tip .value {
		font-family: var(--font-mono);
		font-weight: 600;
	}
	:global(.bench-selected) {
		stroke: var(--accent);
		stroke-dasharray: 3 3;
	}
</style>
