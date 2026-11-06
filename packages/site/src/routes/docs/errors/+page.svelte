<script lang="ts">
	import { base, resolve } from '$app/paths';
	import { useEventListener } from 'runed';
	import type MiniSearch from 'minisearch';
	import { GROUPS, SEARCH_OPTIONS, SEARCH_QUERY } from '$lib/errors';
	import icon from '$lib/images/icon.webp';

	let { data } = $props();

	const groups = $derived(GROUPS.map((g) => ({ ...g, errors: data.errors.filter((e) => e.code.startsWith(g.prefix)) })));

	let query = $state('');
	let index = $state<MiniSearch>();
	let loading: Promise<void> | undefined;

	// The index is prerendered; it is fetched only once someone starts to search.
	function loadIndex() {
		loading ??= (async () => {
			const [{ default: MiniSearch }, json] = await Promise.all([
				import('minisearch'),
				fetch(`${base}/docs/errors/search.json`).then((r) => r.text())
			]);
			index = MiniSearch.loadJSON(json, SEARCH_OPTIONS);
		})();
	}

	const searching = $derived(query.trim().length > 0 && index !== undefined);
	const results = $derived(
		searching ? index!.search(query.trim(), SEARCH_QUERY).map((r) => ({ code: r.id as string, title: r.title as string })) : []
	);
	const matches = $derived(new Set(results.map((r) => r.code)));
	const shown = (code: string) => !searching || matches.has(code);

	function onkeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && results[0]) {
			location.hash = results[0].code;
			(e.target as HTMLInputElement).blur();
		} else if (e.key === 'Escape') {
			query = '';
		}
	}

	// There is one search box per layout (sidebar, or top of the page on a phone); `/`
	// focuses whichever one is on screen.
	useEventListener(() => window, 'keydown', (e: KeyboardEvent) => {
		if (e.key !== '/' || document.activeElement?.tagName === 'INPUT') return;
		const input = [...document.querySelectorAll<HTMLInputElement>('[data-testid=error-search]')].find((i) => i.offsetParent);
		if (!input) return;
		e.preventDefault();
		input.focus();
	});

	let active = $state<string>();
	function updateActive() {
		let cur: string | undefined;
		for (const e of data.errors) {
			const el = document.getElementById(e.code);
			if (el && !el.hidden && el.getBoundingClientRect().top <= 100) cur = e.code;
		}
		active = cur;
	}
	useEventListener(() => window, 'scroll', updateActive, { passive: true });
	$effect(updateActive);

	// Scrolls only the sidebar: scrollIntoView would also move the page.
	let nav = $state<HTMLElement>();
	$effect(() => {
		const link = active && nav?.querySelector<HTMLElement>(`a[href="#${active}"]`);
		if (!nav || !link) return;
		const top = link.offsetTop;
		if (top < nav.scrollTop || top + link.offsetHeight > nav.scrollTop + nav.clientHeight)
			nav.scrollTop = top - nav.clientHeight / 2;
	});
</script>

<svelte:head>
	<title>Diagnostics — toy</title>
	<meta name="description" content="Every error and warning code the toy compiler reports, and how to fix it." />
</svelte:head>

{#snippet search(cls: string)}
	<label class="search {cls}">
		<span class="sr-only">Search diagnostics</span>
		<input
			bind:value={query}
			onfocus={loadIndex}
			oninput={loadIndex}
			{onkeydown}
			type="search"
			placeholder="Search codes and messages"
			autocomplete="off"
			spellcheck="false"
			data-testid="error-search"
		/>
		<kbd>/</kbd>
	</label>
{/snippet}

<div class="mx-auto min-h-screen max-w-6xl border-x" style="border-color: var(--border)">
	<div class="grid md:grid-cols-[260px_minmax(0,1fr)]">
		<aside class="sticky top-0 hidden h-screen flex-col border-r pt-20 md:flex" style="border-color: var(--border)">
			<div class="px-6">
				<a href={resolve('/')} class="mb-6 inline-flex items-center gap-2">
					<img src={icon} alt="toy" width="28" height="28" class="h-7 w-7" />
				</a>
				{@render search('')}
			</div>

			<nav bind:this={nav} class="relative mt-5 min-h-0 flex-1 overflow-y-auto px-6 pb-10 text-[0.8rem]" aria-label="Diagnostic codes" data-testid="error-nav">
				{#if searching}
					<p class="mb-2 font-mono text-[0.6rem] uppercase tracking-widest" style="color: var(--fg-muted)">
						{results.length} {results.length === 1 ? 'result' : 'results'}
					</p>
					{#each results as r (r.code)}
						<a href="#{r.code}" class="side-code" class:active={active === r.code}>
							<span class="font-mono">{r.code}</span>
							<span class="truncate">{r.title}</span>
						</a>
					{/each}
				{:else}
					{#each groups as g, i}
						<a
							href="#group-{g.prefix}"
							class="mb-1 flex items-center justify-between font-mono text-[0.6rem] uppercase tracking-widest"
							class:mt-5={i > 0}
							style="color: var(--fg-muted)"
						>
							{g.label} <span>{g.errors.length}</span>
						</a>
						{#each g.errors as e (e.code)}
							<a href="#{e.code}" class="side-code" class:active={active === e.code}>
								<span class="font-mono">{e.code}</span>
								<span class="truncate">{e.title}</span>
							</a>
						{/each}
					{/each}
				{/if}
			</nav>
		</aside>

		<main class="min-w-0 px-6 pb-24 pt-20 sm:px-10 md:px-12">
			<a href={resolve('/')} class="link text-[0.82rem]">← toy</a>
			<h1 class="mt-8 text-4xl">Diagnostics</h1>
			<p class="mt-3 text-base leading-snug" style="color: var(--fg-muted)">
				Every error and warning the compiler can report, with an example and how to fix it. To read a page
				in your terminal, run <code class="code">toy explain T0048</code>.
			</p>
			{@render search('mt-6 md:hidden')}

			{#if searching && results.length === 0}
				<p class="mt-14 text-sm" style="color: var(--fg-muted)" data-testid="error-no-results">
					No diagnostic matches “{query.trim()}”.
				</p>
			{/if}

			{#each groups as g}
				{#if g.errors.some((e) => shown(e.code))}
					<h2
						id="group-{g.prefix}"
						class="mt-14 scroll-mt-8 border-b pb-2 font-mono text-[0.7rem] uppercase tracking-widest"
						style="border-color: var(--border); color: var(--fg-muted)"
					>
						{g.label}
					</h2>
				{/if}
				{#each g.errors as e (e.code)}
					<section id={e.code} class="scroll-mt-8 border-b py-7" style="border-color: var(--border)" hidden={!shown(e.code)}>
						<h3 class="flex items-baseline gap-3 text-sm font-medium tracking-tight">
							<a href="#{e.code}" class="font-mono text-[0.8rem] transition-colors hover:text-[var(--accent)]">{e.code}</a>
							<span>{e.title}</span>
						</h3>
						<div class="prose-toy mt-3 text-sm leading-relaxed">{@html e.html}</div>
					</section>
				{/each}
			{/each}
		</main>
	</div>
</div>

<style>
	.search {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		border: 1.5px solid var(--border);
		border-radius: 0.6rem;
		padding: 0.35rem 0.6rem;
		background: var(--bg);
		box-shadow: 2px 2px 0 var(--border);
		transition: border-color 0.12s, box-shadow 0.12s;
	}
	.search:focus-within {
		border-color: var(--toy-teal);
		box-shadow: 2px 2px 0 var(--toy-teal);
	}
	.search input {
		min-width: 0;
		flex: 1;
		background: transparent;
		font-size: 0.8rem;
		outline: none;
	}
	.search input::-webkit-search-cancel-button {
		display: none;
	}
	.search kbd {
		border: 1px solid var(--border);
		border-radius: 0.3rem;
		padding: 0 0.35rem;
		font-family: var(--font-mono);
		font-size: 0.65rem;
		color: var(--fg-muted);
	}
	.side-code {
		display: grid;
		grid-template-columns: 3.4rem minmax(0, 1fr);
		gap: 0.4rem;
		padding: 0.15rem 0;
		color: var(--fg-muted);
		transition: color 0.12s;
	}
	.side-code:hover {
		color: var(--accent);
	}
	.side-code.active {
		color: var(--accent);
		font-weight: 600;
	}
	.prose-toy :global(p) {
		margin: 0.6rem 0;
		color: var(--fg-muted);
	}
	.prose-toy :global(ul) {
		margin: 0.6rem 0;
		padding-left: 1.2rem;
		list-style: disc;
		color: var(--fg-muted);
	}
	.prose-toy :global(pre) {
		margin: 0.8rem 0;
		padding: 0.9rem 1rem;
		overflow-x: auto;
		border: 1px solid var(--border);
		border-radius: 0.6rem;
		background: var(--code-bg);
		font-size: 0.75rem;
	}
	.prose-toy :global(:not(pre) > code) {
		font-family: var(--font-mono);
		font-size: 0.82em;
		padding: 0.1em 0.35em;
		border-radius: 0.3rem;
		background: var(--code-bg);
		border: 1px solid var(--border);
		color: var(--fg);
	}
</style>
