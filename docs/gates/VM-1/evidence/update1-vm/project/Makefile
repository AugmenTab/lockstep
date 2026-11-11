build/test: src/calc.c src/test.c
	mkdir -p build && cc -O2 -o build/test src/calc.c src/test.c
test: build/test
	./build/test
