function main() {
  const words = [];
  for (let i = 0; i < 2000; i++) words.push("w" + String(i % 97));
  const text = words.join(" ");
  const counts = new Map();
  let total = 0;
  for (let round = 0; round < 200; round++) {
    for (const w of text.split(" ")) counts.set(w, (counts.get(w) ?? 0) + 1);
    for (const c of text) if (c === "w") total++;
  }
  for (const [k, v] of counts) total += k.length * v;
  console.log(total);
}

main();
