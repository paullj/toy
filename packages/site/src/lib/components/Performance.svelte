<script lang="ts">
	import { onMount } from 'svelte';
	import Bars from '$lib/components/Bars.svelte';

	const ms = (v: number) => (v >= 1000 ? `${(v / 1000).toFixed(1)} s` : `${v} ms`);

	// Placeholder numbers until we pick what the homepage compares against.
	const charts = [
		{
			title: 'Runtime',
			color: 'var(--toy-teal)',
			caption: 'loops · wall time, lower is better',
			bars: [
				{ label: 'toy', value: 700, toy: true },
				{ label: 'C', value: 620 },
				{ label: 'Go', value: 810 },
				{ label: 'Python', value: 9400 }
			]
		},
		{
			title: 'Compile time',
			color: 'var(--toy-yellow)',
			caption: 'build · 200 modules × 50 functions',
			bars: [
				{ label: 'cold', value: 1200, toy: true },
				{ label: 'warm, one edit', value: 90, toy: true },
				{ label: 'warm, no edit', value: 40, toy: true }
			]
		}
	].map((c) => ({ ...c, bars: c.bars.map((b) => ({ ...b, text: ms(b.value) })) }));

	let current = $state(0);
	let interactive = $state(false);
	onMount(() => (interactive = true));
</script>

<div class="mt-6">
	<div role="tablist" class="flex flex-wrap gap-2.5" class:hidden={!interactive}>
		{#each charts as c, i}
			<button
				role="tab"
				aria-selected={current === i}
				class="block-tab"
				class:active={current === i}
				style="--block: {c.color}"
				onclick={() => (current = i)}
			>
				{c.title}
			</button>
		{/each}
	</div>

	<div class="mt-5" class:stack={interactive}>
		{#each charts as c, i}
			<div role="tabpanel" class="panel" class:off={interactive && current !== i}>
				{#if !interactive}<p class="mb-3 text-sm font-semibold">{c.title}</p>{/if}
				<Bars caption={c.caption} bars={c.bars} />
			</div>
		{/each}
	</div>
</div>

<style>
	.stack {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
	}
	.stack > .panel {
		grid-area: 1 / 1;
	}
	.off {
		visibility: hidden;
	}
</style>
