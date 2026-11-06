<script lang="ts">
	type Bar = { label: string; value: number; text: string; toy?: boolean };

	let { caption, bars }: { caption: string; bars: Bar[] } = $props();

	const max = $derived(Math.max(...bars.map((b) => b.value)));
</script>

<figure>
	<figcaption class="flex items-center justify-between gap-2 font-mono text-[0.7rem]" style="color: var(--fg-muted)">
		<span>{caption}</span>
		<span class="text-[0.6rem] uppercase tracking-widest">Placeholder</span>
	</figcaption>
	<div class="mt-4 flex flex-col gap-2.5">
		{#each bars as b}
			<div class="grid grid-cols-[7.5rem_minmax(0,1fr)_3.5rem] items-center gap-3 font-mono text-[0.75rem]">
				<span class:font-semibold={b.toy}>{b.label}</span>
				<div
					class="h-3.5 rounded-[3px]"
					style="width: {(b.value / max) * 100}%; background: {b.toy ? 'var(--toy-teal)' : 'color-mix(in srgb, var(--fg-muted) 35%, transparent)'}"
				></div>
				<span class="text-right" style="color: var(--fg-muted)">{b.text}</span>
			</div>
		{/each}
	</div>
</figure>
