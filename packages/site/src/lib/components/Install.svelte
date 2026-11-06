<script lang="ts">
	type Os = { id: string; label: string; command: string; supported: boolean };

	const SITE = 'https://paullj.github.io/toy';

	// Placeholder commands: no install script or release binaries exist yet.
	const systems: Os[] = [
		{ id: 'macos', label: 'macOS', command: `curl -fsSL ${SITE}/install.sh | sh`, supported: true },
		{ id: 'linux', label: 'Linux', command: `curl -fsSL ${SITE}/install.sh | sh`, supported: false },
		{ id: 'windows', label: 'Windows', command: `powershell -c "irm ${SITE}/install.ps1 | iex"`, supported: false }
	];

	const fromSource = `git clone https://github.com/paullj/toy-compiler
cd toy-compiler && zig build -Doptimize=ReleaseFast`;

	const colors = ['var(--toy-red)', 'var(--toy-yellow)', 'var(--toy-teal)'];

	let current = $state(systems[0].id);
	const os = $derived(systems.find((s) => s.id === current)!);

	let copied = $state(false);
	async function copy() {
		await navigator.clipboard.writeText(fromSource);
		copied = true;
		setTimeout(() => (copied = false), 1500);
	}
</script>

<div id="install" class="mt-8 scroll-mt-8">
	<div role="tablist" aria-label="Operating system" class="os-tabs">
		{#each systems as s, i}
			<button
				role="tab"
				aria-selected={current === s.id}
				class="os-tab"
				class:active={current === s.id}
				style="--block: {colors[i]}"
				onclick={() => (current = s.id)}
			>
				{s.label}
			</button>
		{/each}
	</div>

	<div class="install-box" role="tabpanel">
		<div class="flex items-start gap-3 px-4 py-3 font-mono text-[0.75rem] leading-relaxed">
			<span class="select-none" style="color: var(--fg-muted)">$</span>
			<code class="min-w-0 flex-1 [overflow-wrap:anywhere] opacity-50" data-testid="install-command">{os.command}</code>
			<span class="tag">Soon</span>
		</div>

		<div class="border-t px-4 py-3 text-[0.8rem] leading-snug" style="border-color: var(--border); color: var(--fg-muted)">
			{#if os.supported}
				<div class="flex items-center justify-between gap-3">
					<span>No installer yet. Build from source with <a href="https://ziglang.org/download/" class="link">Zig 0.16</a>:</span>
					<button class="copy-btn" onclick={copy} aria-label="Copy build commands">{copied ? 'Copied' : 'Copy'}</button>
				</div>
				<pre class="mt-2 whitespace-pre-wrap [overflow-wrap:anywhere] font-mono text-[0.75rem] leading-relaxed" style="color: var(--fg)"><code
						>{fromSource}</code
					></pre>
			{:else}
				<span data-testid="install-unsupported">{os.label} is not supported yet. toy only emits macOS arm64 binaries today.</span>
			{/if}
		</div>
	</div>
</div>

<style>
	.os-tabs {
		display: flex;
		margin-bottom: -1.5px;
	}
	.os-tab {
		position: relative;
		border: 1.5px solid var(--border);
		padding: 0.35rem 0.9rem;
		font-size: 0.8rem;
		font-weight: 600;
		color: var(--fg-muted);
		background: var(--bg);
		transition: color 0.12s, background-color 0.12s, border-color 0.12s;
	}
	.os-tab + .os-tab {
		margin-left: -1.5px;
	}
	.os-tab:first-child {
		border-top-left-radius: 0.6rem;
	}
	.os-tab:last-child {
		border-top-right-radius: 0.6rem;
	}
	.os-tab:hover {
		z-index: 1;
		color: var(--fg);
		border-color: var(--block);
	}
	.os-tab.active {
		z-index: 2;
		color: var(--fg);
		background: color-mix(in srgb, var(--block) 18%, var(--bg));
		border-color: var(--block);
	}
	.install-box {
		border: 1.5px solid var(--border);
		border-radius: 0 0.75rem 0.75rem 0.75rem;
		background: var(--code-bg);
		box-shadow: 3px 3px 0 var(--border);
	}
	.tag {
		flex-shrink: 0;
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0 0.5rem;
		font-size: 0.6rem;
		text-transform: uppercase;
		letter-spacing: 0.1em;
		color: var(--fg-muted);
	}
	.copy-btn {
		flex-shrink: 0;
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
