function main() {
  const keep = [];
  let total = 0;
  for (let i = 0; i < 1000000; i++) {
    const v = [i, i + 1, i + 2];
    total += v[1];
    if (i % 20 === 0) keep.push(v);
  }
  console.log(total + keep.length);
}

main();
