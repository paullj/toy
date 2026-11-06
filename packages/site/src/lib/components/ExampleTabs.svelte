<script lang="ts">
	import { onMount } from 'svelte';
	import Code from '$lib/components/Code.svelte';

	type Example = { title: string; blurb: string; file: string; code: string };

	let { examples }: { examples: Example[] } = $props();

	let current = $state(0);
	// Without JS the tabs cannot switch, so every example stays visible until hydration.
	let interactive = $state(false);
	onMount(() => (interactive = true));
</script>

<div class="mt-6 max-w-2xl">
	<div role="tablist" class="flex flex-wrap gap-1.5" class:hidden={!interactive}>
		{#each examples as e, i}
			<button
				role="tab"
				aria-selected={current === i}
				data-file={e.file}
				class="pill"
				class:active={current === i}
				onclick={() => (current = i)}
			>
				{e.title}
			</button>
		{/each}
	</div>

	{#each examples as e, i}
		<div role="tabpanel" class="mt-4" hidden={interactive && current !== i}>
			<p class="max-w-[54ch] text-sm leading-snug" style="color: var(--fg-muted)">
				{#if !interactive}<strong style="color: var(--fg)">{e.title}.</strong>{/if}
				{@html e.blurb}
			</p>
			<Code code={e.code} filename={e.file} />
		</div>
	{/each}
</div>
