<script lang="ts">
	// Placeholder numbers until we pick what the homepage compares against.
	const bars = [
		{ lang: 'toy', ms: 700 },
		{ lang: 'C', ms: 620 },
		{ lang: 'Go', ms: 810 },
		{ lang: 'Python', ms: 9400 }
	];

	const max = Math.max(...bars.map((b) => b.ms));
	const label = (ms: number) => (ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${ms} ms`);
</script>

<figure class="mt-7 max-w-2xl rounded-xl border" style="border-color: var(--border); background: var(--code-bg)" data-testid="speed-bars">
	<figcaption
		class="flex items-center justify-between gap-2 border-b px-4 py-2 font-mono text-[0.7rem]"
		style="border-color: var(--border); color: var(--fg-muted)"
	>
		<span>loops · wall time, lower is better</span>
		<span class="uppercase tracking-widest text-[0.6rem]">Placeholder</span>
	</figcaption>
	<div class="flex flex-col gap-2.5 px-4 py-5">
		{#each bars as b}
			<div class="grid grid-cols-[4rem_minmax(0,1fr)_3.5rem] items-center gap-3 font-mono text-[0.75rem]">
				<span class:font-semibold={b.lang === 'toy'}>{b.lang}</span>
				<div class="h-3.5 rounded-[3px]">
					<div
						class="h-full rounded-[3px]"
						style="width: {(b.ms / max) * 100}%; background: {b.lang === 'toy' ? 'var(--toy-teal)' : 'color-mix(in srgb, var(--fg-muted) 35%, transparent)'}"
					></div>
				</div>
				<span class="text-right" style="color: var(--fg-muted)">{label(b.ms)}</span>
			</div>
		{/each}
	</div>
</figure>
