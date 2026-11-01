class Tree {
  constructor(left, right) {
    this.left = left;
    this.right = right;
  }
}

function make(d) {
  if (d === 0) return new Tree(null, null);
  return new Tree(make(d - 1), make(d - 1));
}

function check(t) {
  if (t.left === null) return 1;
  return 1 + check(t.left) + check(t.right);
}

function main() {
  const maxDepth = 13;
  let total = check(make(maxDepth + 1));
  const longLived = make(maxDepth);
  for (let d = 4; d <= maxDepth; d += 2) {
    const iters = 1 << (maxDepth - d + 4);
    for (let i = 0; i < iters; i++) total += check(make(d));
  }
  console.log(total + check(longLived));
}

main();
