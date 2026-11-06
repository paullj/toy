<script lang="ts">
	type Os = { id: string; label: string; command: string; supported: boolean };

	const REPO = 'https://raw.githubusercontent.com/paullj/toy-compiler/main';

	// Placeholder commands: no install script or release binaries exist yet.
	const systems: Os[] = [
		{ id: 'macos', label: 'macOS', command: `curl -fsSL ${REPO}/install.sh | sh`, supported: true },
		{ id: 'linux', label: 'Linux', command: `curl -fsSL ${REPO}/install.sh | sh`, supported: false },
		{ id: 'windows', label: 'Windows', command: `powershell -c "irm ${REPO}/install.ps1 | iex"`, supported: false }
	];

	const fromSource = `git clone https://github.com/paullj/toy-compiler
cd toy-compiler
zig build -Doptimize=ReleaseFast
./zig-out/bin/toy --help`;

	let current = $state(systems[0].id);
	const os = $derived(systems.find((s) => s.id === current)!);

	let copied = $state<string>();
	async function copy(text: string) {
		await navigator.clipboard.writeText(text);
		copied = text;
		setTimeout(() => copied === text && (copied = undefined), 1500);
	}
</script>

<div class="mt-7 max-w-2xl">
	<div role="tablist" aria-label="Operating system" class="flex gap-1.5">
		{#each systems as s}
			<button
				role="tab"
				aria-selected={current === s.id}
				class="os-tab"
				class:active={current === s.id}
				onclick={() => (current = s.id)}
			>
				{s.label}
			</button>
		{/each}
	</div>

	<div class="mt-3 rounded-xl border" style="border-color: var(--border); background: var(--code-bg)" role="tabpanel">
		<div class="flex items-center gap-3 px-4 py-3">
			<span class="select-none font-mono text-[0.75rem]" style="color: var(--fg-muted)">$</span>
			<code class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-[0.75rem] opacity-50" data-testid="install-command">
				{os.command}
			</code>
			<span class="shrink-0 rounded-full border px-2 py-0.5 font-mono text-[0.6rem] uppercase tracking-widest" style="border-color: var(--border); color: var(--fg-muted)">
				Soon
			</span>
		</div>
	</div>

	{#if os.supported}
		<p class="mt-5 text-sm leading-snug" style="color: var(--fg-muted)">
			There is no installer yet. For now, build toy from source with
			<a href="https://ziglang.org/download/" class="link">Zig 0.16</a>:
		</p>
		<figure class="relative mt-3 rounded-xl border" style="border-color: var(--border); background: var(--code-bg)">
			<button class="copy-btn absolute right-3 top-3" onclick={() => copy(fromSource)} aria-label="Copy build commands">
				{copied === fromSource ? 'Copied' : 'Copy'}
			</button>
			<pre class="overflow-x-auto py-4 pl-4 pr-20 font-mono text-[0.75rem] leading-relaxed"><code>{fromSource}</code></pre>
		</figure>
	{:else}
		<p class="mt-5 text-sm leading-snug" style="color: var(--fg-muted)" data-testid="install-unsupported">
			{os.label} is not supported yet. toy only emits macOS arm64 binaries today.
		</p>
	{/if}
</div>

<style>
	.os-tab {
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0.25rem 0.8rem;
		font-size: 0.8rem;
		color: var(--fg-muted);
		transition: color 0.15s, border-color 0.15s, background-color 0.15s;
	}
	.os-tab:hover {
		color: var(--accent);
	}
	.os-tab.active {
		color: var(--fg);
		background: var(--code-bg);
		border-color: color-mix(in srgb, var(--accent) 45%, var(--border));
	}
	.copy-btn {
		font-family: var(--font-mono);
		font-size: 0.65rem;
		text-transform: uppercase;
		letter-spacing: 0.1em;
		color: var(--fg-muted);
		transition: color 0.15s;
	}
	.copy-btn:hover {
		color: var(--accent);
	}
</style>
