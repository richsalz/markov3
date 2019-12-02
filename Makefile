CFLAGS=-g -Wall -Wextra -Wno-unneeded-internal-declaration

all: markov3 tags

clean:
	rm -f markov3 tags

markov3: markov3.c
	$(CC) $(CFLAGS) -o $@ markov3.c

tags: markov3.c
	ctags $?
