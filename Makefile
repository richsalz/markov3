CFLAGS=-O -Wall -Wextra -Wno-unneeded-internal-declaration

all: markov3 tags

clean:
	@rm -f markov3 markov3.o markov3.c tags

markov3: markov3.o
	$(CC) $(CFLAGS)  -o $@ markov3.o

markov3.c: markov3.l
	lex markov3.l
	mv lex.yy.c markov3.c

tags: markov3.c
	ctags $?
