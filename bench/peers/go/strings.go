package main

import (
	"fmt"
	"strconv"
	"strings"
)

func main() {
	words := make([]string, 0, 2000)
	for i := 0; i < 2000; i++ {
		words = append(words, "w"+strconv.Itoa(i%97))
	}
	text := strings.Join(words, " ")
	counts := map[string]int{}
	total := 0
	for round := 0; round < 200; round++ {
		for _, w := range strings.Split(text, " ") {
			counts[w]++
		}
		for _, c := range text {
			if c == 'w' {
				total++
			}
		}
	}
	for k, v := range counts {
		total += len(k) * v
	}
	fmt.Println(total)
}
