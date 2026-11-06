<!-- Copied from a real `toy check` run, so it must change with the compiler's output. -->
<figure class="my-4 rounded-xl border" style="border-color: var(--border); background: var(--code-bg)">
	<figcaption
		class="border-b px-4 py-2 font-mono text-[0.7rem]"
		style="border-color: var(--border); color: var(--fg-muted)"
	>
		$ toy check triangle.toy
	</figcaption>
	<pre class="overflow-hidden whitespace-pre-wrap px-4 py-4 font-mono text-[0.7rem] leading-relaxed"><code
			><span class="err">error[T0048]</span><strong>: non-exhaustive match: missing variant 'Triangle'; add the missing arm(s) or a '_' arm</strong>
<span class="gutter"> --></span> triangle.toy:4:5
<span class="gutter">  |</span>
<span class="gutter">4 |</span>     match shape {'{'}
<span class="gutter">  |</span>     <span class="err">^^^^^^^^^^^ non-exhaustive match: missing variant 'Triangle'; add the missing arm(s) or a '_' arm</span>
1 error(s)</code
		></pre>
</figure>

<style>
	.err {
		color: var(--toy-red);
		font-weight: 600;
	}
	.gutter {
		color: var(--toy-teal);
	}
</style>
