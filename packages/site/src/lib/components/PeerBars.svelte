<script lang="ts">
	import { BarChart, Tooltip } from 'layerchart';
	import { scaleLinear, scaleLog } from 'd3-scale';
	import { vsToyLabel, type MetricKey, type PeerBar } from '$lib/bench';

	let {
		bars,
		metric,
		format,
		log,
		toolchains,
		height = 200
	}: {
		bars: PeerBar[];
		metric: MetricKey;
		format: (v: number) => string;
		log: boolean;
		toolchains: Record<string, { version: string; flags: string }>;
		height?: number;
	} = $props();

	// A log axis has no zero, so its domain pads the extremes; a linear one starts at zero.
	const values = $derived(bars.map((b) => b.value));
	const yDomain = $derived(log ? [Math.min(...values) / 2, Math.max(...values) * 2] : [0, null]);
	// d3's own log ticks label every 2..9 multiple; 1 and 3 per decade read cleanly.
	const logTicks = $derived(
		Array.from({ length: 2 * (Math.ceil(Math.log10(yDomain[1]!)) - Math.floor(Math.log10(yDomain[0]!))) }, (_, i) => {
			const decade = 10 ** (Math.floor(Math.log10(yDomain[0]!)) + Math.floor(i / 2));
			return decade * (i % 2 ? 3 : 1);
		}).filter((t) => t >= yDomain[0]! && t <= yDomain[1]!)
	);
	const ms = (s: number) => `${(s * 1000).toFixed(1)} ms`;
</script>

<div style="height: {height}px">
	<BarChart
		data={bars}
		x="lang"
		y="value"
		xDomain={bars.map((b) => b.lang)}
		yScale={log ? scaleLog() : scaleLinear()}
		{yDomain}
		yNice={!log}
		seriesLayout="overlap"
		series={[
			{ key: 'toy', value: 'value', data: bars.filter((b) => b.lang === 'toy'), color: 'var(--toy-teal)' },
			{ key: 'peers', value: 'value', data: bars.filter((b) => b.lang !== 'toy'), color: 'var(--peer-bar)' }
		]}
		padding={{ top: 8, right: 8, bottom: 22, left: 64 }}
		props={{ yAxis: { format, ticks: log ? logTicks : 4 }, grid: { yTicks: log ? logTicks : 4 }, bars: { stroke: 'none' } }}
	>
		{#snippet tooltip({ context })}
			<Tooltip.Root {context}>
				{#snippet children({ data })}
					{@const b = data as PeerBar}
					{@const m = b.result.metrics}
					<div class="peer-tip">
						<div><strong>{b.lang}</strong> <span class="muted">{toolchains[b.lang]?.version ?? ''}</span></div>
						<div class="value">{format(b.value)}</div>
						{#if b.lang !== 'toy'}<div>{vsToyLabel(b.vsToy, metric)}</div>{/if}
						<div class="muted">wall {ms(m.wall_min_s)}..{ms(m.wall_max_s)} · ± {ms(m.wall_stddev_s)}</div>
						{#if toolchains[b.lang]}<div class="muted"><code>{toolchains[b.lang].flags}</code></div>{/if}
						{#if !b.result.checksum_ok}<div class="bad">checksum mismatch</div>{/if}
					</div>
				{/snippet}
			</Tooltip.Root>
		{/snippet}
	</BarChart>
</div>

<style>
	.peer-tip {
		max-width: 22rem;
		font-size: 0.75rem;
		line-height: 1.4;
	}
	.peer-tip .muted {
		color: var(--fg-muted);
	}
	.peer-tip .value {
		font-family: var(--font-mono);
		font-weight: 600;
	}
	.peer-tip .bad {
		color: var(--toy-red);
	}
</style>
