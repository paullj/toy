package main

import "fmt"

func main() {
	var keep [][]int
	total := 0
	for i := 0; i < 1000000; i++ {
		v := []int{i, i + 1, i + 2}
		total += v[1]
		if i%20 == 0 {
			keep = append(keep, v)
		}
	}
	fmt.Println(total + len(keep))
}
