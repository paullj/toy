<script lang="ts">
	import { onMount } from 'svelte';
	import { highlightLines } from '$lib/toy-syntax';

	let { code, filename }: { code: string; filename?: string } = $props();

	const source = $derived(code.trim());
	const lines = $derived(highlightLines(source));

	let host: HTMLDivElement;
	let live = $state(false);

	// The static render is the first paint (and the no-JS page); a block becomes a live
	// editor only once it scrolls near the viewport, so the editor and language server
	// load only for readers who reach the examples.
	onMount(() => {
		let view: { destroy(): void } | undefined;
		const io = new IntersectionObserver(
			async (entries) => {
				if (!entries.some((e) => e.isIntersecting)) return;
				io.disconnect();
				const { mountBlock } = await import('$lib/lsp/block');
				view = mountBlock(host, source, `file:///examples/${filename ?? 'block.toy'}`);
				live = true;
			},
			{ rootMargin: '200px' }
		);
		io.observe(host);
		return () => {
			io.disconnect();
			view?.destroy();
		};
	});
</script>

<figure
	class="my-4 rounded-xl border"
	style="border-color: var(--border); background: var(--code-bg)"
>
	{#if filename}
		<figcaption
			class="flex items-center gap-2 border-b px-4 py-1.5 font-mono text-[0.7rem]"
			style="border-color: var(--border); color: var(--fg-muted)"
		>
			{filename}
			<span class="run ml-auto" data-tip="Running examples is not supported yet">
				<button type="button" disabled aria-label="Run (not supported yet)">
					<svg viewBox="0 0 12 12" width="10" height="10" aria-hidden="true"><path d="M3 1.5v9l7.5-4.5z" fill="currentColor" /></svg>
					Run
				</button>
			</span>
		</figcaption>
	{/if}
	<div bind:this={host} class="overflow-x-auto">
		{#if !live}
			<pre class="py-4 font-mono text-[0.75rem] leading-relaxed"><code class="block"
					>{#each lines as line}<span class="block h-[1lh] px-4"
							>{#each line as t}<span class={t.cls}>{t.text}</span>{/each}</span
						>{/each}</code
				></pre>
		{/if}
	</div>
</figure>

<style>
	.run {
		position: relative;
	}
	.run button {
		display: inline-flex;
		align-items: center;
		gap: 0.35rem;
		border: 1.5px solid var(--border);
		border-radius: 0.5rem;
		padding: 0.1rem 0.55rem;
		font-size: 0.65rem;
		text-transform: uppercase;
		letter-spacing: 0.08em;
		background: var(--bg);
		color: var(--fg-muted);
		opacity: 0.6;
		cursor: not-allowed;
	}
	/* A disabled button gets no pointer events, so the wrapper shows the tooltip. */
	.run::after {
		content: attr(data-tip);
		position: absolute;
		right: 0;
		bottom: calc(100% + 6px);
		z-index: 10;
		white-space: nowrap;
		padding: 0.3rem 0.55rem;
		border: 1.5px solid var(--border);
		border-radius: 0.5rem;
		background: var(--bg);
		color: var(--fg);
		font-family: var(--font-sans);
		font-size: 0.75rem;
		box-shadow: 2px 2px 0 var(--border);
		opacity: 0;
		pointer-events: none;
		transform: translateY(2px);
		transition: opacity 0.12s, transform 0.12s;
	}
	.run:hover::after {
		opacity: 1;
		transform: none;
	}
</style>
