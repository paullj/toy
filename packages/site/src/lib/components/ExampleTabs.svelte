<script lang="ts">
	import { onMount } from 'svelte';
	import Code from '$lib/components/Code.svelte';

	type Example = { title: string; blurb: string; file: string; code: string };

	let { examples }: { examples: Example[] } = $props();

	const colors = ['var(--toy-red)', 'var(--toy-yellow)', 'var(--toy-teal)', 'var(--toy-navy)'];

	let current = $state(0);
	// Without JS the tabs cannot switch, so every example stays visible until hydration.
	let interactive = $state(false);
	onMount(() => (interactive = true));
</script>

<div class="mt-5 max-w-2xl">
	<div role="tablist" class="flex flex-wrap gap-2.5" class:hidden={!interactive}>
		{#each examples as e, i}
			<button
				role="tab"
				aria-selected={current === i}
				data-file={e.file}
				class="block-tab"
				class:active={current === i}
				style="--block: {colors[i % colors.length]}"
				onclick={() => (current = i)}
			>
				{e.title}
			</button>
		{/each}
	</div>

	<!-- Every panel shares one grid cell, so the box is as tall as the tallest example and
	     switching tabs never moves the content below. -->
	<div class="mt-4" class:stack={interactive}>
		{#each examples as e, i}
			<div role="tabpanel" class="panel" class:off={interactive && current !== i}>
				<p class="max-w-[54ch] text-sm leading-snug" style="color: var(--fg-muted)">
					{#if !interactive}<strong style="color: var(--fg)">{e.title}.</strong>{/if}
					{@html e.blurb}
				</p>
				<Code code={e.code} filename={e.file} />
			</div>
		{/each}
	</div>
</div>

<style>
	.stack {
		display: grid;
	}
	.stack > .panel {
		grid-area: 1 / 1;
		display: flex;
		flex-direction: column;
	}
	.stack > .panel :global(figure) {
		flex: 1;
		margin-bottom: 0;
	}
	.off {
		visibility: hidden;
	}

	/* A tab is a toy block: the hard offset shadow is the block it sits on. */
	.block-tab {
		border: 1.5px solid var(--border);
		border-radius: 0.6rem;
		padding: 0.3rem 0.8rem;
		font-size: 0.8rem;
		font-weight: 600;
		background: var(--bg);
		color: var(--fg-muted);
		box-shadow: 2px 2px 0 var(--border);
		transition: transform 0.12s, box-shadow 0.12s, border-color 0.12s, color 0.12s, background-color 0.12s;
	}
	.block-tab:hover {
		color: var(--fg);
		border-color: var(--block);
		box-shadow: 3px 3px 0 var(--block);
		transform: translate(-1px, -1px);
	}
	.block-tab.active {
		color: var(--fg);
		background: color-mix(in srgb, var(--block) 18%, var(--bg));
		border-color: var(--block);
		box-shadow: 1px 1px 0 var(--block);
		transform: translate(1px, 1px);
	}
</style>
