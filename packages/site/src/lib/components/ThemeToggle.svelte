<script lang="ts">
	import { userPrefersMode, setMode } from 'mode-watcher';

	let { class: klass = '' }: { class?: string } = $props();

	const order = ['system', 'light', 'dark'] as const;
	const colors = { system: 'var(--toy-teal)', light: 'var(--toy-yellow)', dark: 'var(--toy-navy)' };

	function cycle() {
		const i = order.indexOf(userPrefersMode.current as (typeof order)[number]);
		setMode(order[(i + 1) % order.length]);
	}
</script>

<button
	type="button"
	onclick={cycle}
	title="Theme: click to cycle system / light / dark"
	class="block-tab lowercase {klass}"
	style="--block: {colors[userPrefersMode.current as (typeof order)[number]] ?? colors.system}"
>
	{userPrefersMode.current}
</button>
