/*
 * Copyright (c) 1986, 1987 by Joe Buck
 *
 * Permission is granted to use, redistribute, or modify this program,
 * as long as you don't pretend you wrote it.  Send improvements or
 * bug reports to {ihnp4,hplabs,ames,sun}!oliveb!epimass!jbuck.
 *
 * The program generates simulated Usenet articles, given Usenet articles
 * as input.
 *
 * This program constructs a table of frequencies for a token appearing,
 * given the two preceding tokens.  A "token" is a sequence of non-blank
 * characters.  An entirely blank line is also treated as a token, as is
 * the beginning and end of an article.
 *
 * The program is designed to process news articles, rejecting text from
 * the header, signature, and included text, together with cruft inserted
 * by rn and notes.  A paragraph of included text is treated like a token.
 *
 * After the table is built (and it can be big), articles are generated
 * on the standard output.
 */

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

#define MARGIN 75
#define HSIZE 3557		/* Should be prime */

typedef struct htentry HTENTRY;
typedef struct node NODE;
typedef struct follow FOLLOW;

/*
 * hashtab is a hash table storing all the tokens we encounter.
 */
struct htentry {
    char *text;
    HTENTRY *next;
};

/*
 * node and follow are portions of the structure we're going to build. A
 * node represents something like ("was", "a") in a binary tree.
 * a linked list of follow's contain tokens that may follow ("was", "a")
 */
struct node {
    const char *text;
    const char *text2;
    int count;
    NODE *left;
    NODE *right;
    FOLLOW *following;
};

struct follow {
    int count;
    NODE *node;
    FOLLOW *next;
};


static HTENTRY hashtab[HSIZE];
static NODE *prev_code;
static NODE *root;
static NODE *tknptr;
static FOLLOW *start;
static const char *filterstr;
static char *prev_token;
static int num_files;
static int num_pairs;
static int num_tokens;
static int num_total;
static int verbose;


/*
 * Save a token in the hash table (if not there * already) and return
 * a pointer to the stored copy.
 */
static char *savetoken(const char *text)
{
    int h;
    const char *p;
    HTENTRY *hp;

    /* Hash and lookup. */
    for (num_total++, p = text, h = 0; *p; h += *p++)
	continue;
    for (hp = &hashtab[h % HSIZE]; hp->next != NULL; hp = hp->next) {
	if (strcmp(hp->text, text) == 0)
	    return hp->text;
    }

    /* Not seen before, create a new token. */
    num_tokens++;
    hp->text = strdup(text);
    hp->next = (HTENTRY *)malloc(sizeof (*hp));
    hp->next->next = NULL;
    hp->next->text = NULL;
    return hp->text;
}


/*
 * Strcmp() with special handling for NULL strings.
 */
static int my_strcmp(const char *a, const char *b)
{
    if (a == NULL)
	return b == NULL ? 0 : -1;
    if (b == NULL)
	return 1;
    return strcmp(a, b);
}


/*
 * Insert a token pair into the tree.  Recursive.
 */
static NODE *insert_in_tree(NODE *p, char *text, char *text2)
{
    int cmp;

    if (p == NULL) {
	/* Create a new node. */
	p = (NODE *)malloc(sizeof (*p));
	p->text = text;
	p->text2 = text2;
	p->left = p->right = NULL;
	p->following = NULL;
	p->count = 1;
	tknptr = p;
	num_pairs++;
	if (verbose && (num_pairs % 1000) == 0)
	    fprintf(stderr, "%d pairs\n", num_pairs);
	return p;
    }

    cmp = my_strcmp(p->text, text);
    if (cmp == 0)
	cmp = my_strcmp(p->text2, text2);

    if (cmp == 0) {
	/* It's a match.  Increment the count. */
        tknptr = p;
	p->count++;
    }
    /* Look in the subtrees. */
    else if (cmp < 0)
	p->left = insert_in_tree(p->left, text, text2);
    else
	p->right = insert_in_tree(p->right, text, text2);
    return p;
}

/*
 * Just call insert_in_tree starting at the root
 */
static NODE *insert_token(char *text, char *text2)
{
    root = insert_in_tree(root, text, text2);
    return tknptr;
}

/*
 * Add a successor.
 */
static FOLLOW *insert_in_succ_chain(FOLLOW *sp, NODE *np)
{
    if (sp == NULL) {
	sp = (FOLLOW *)malloc(sizeof (*sp));
	sp->node = np;
	sp->count = 1;
	sp->next = NULL;
    }
    else if (sp->node == np)
	sp->count++;
    else
	sp->next = insert_in_succ_chain(sp->next, np);
    return sp;
}

/*
 * Call insert_in_succ_chain starting at the right place.
 */
void insert_pair(NODE *p1, NODE *p2)
{
    if (p1)
	p1->following = insert_in_succ_chain(p1->following, p2);
    else
	start = insert_in_succ_chain(start, p2);
}

/*
 * We have a new token.  Say the previous two tokens were "one" "way" and the
 * current token is "to".  Then prev_code points to a node for ("one", "way")
 * and token is "to".  This function adds ("way", "to") as a successor to
 * ("one","way") and makes prev_code point to ("way","to").
 */
static void process_token(const char *text)
{
     char *token = savetoken(text);
     NODE *code = insert_token(prev_token, token);

     insert_pair(prev_code, code);
     prev_code = code;
     prev_token = token;
}

/*
 * Open input; file or pipe.
 */
static FILE *openit(const char *arg)
{
    char buff[256];
    FILE *fp;

    if (filterstr == NULL)
	fp = fopen(arg, "r");
    else {
	snprintf(buff, sizeof buff, filterstr, arg);
	fp = popen(buff, "r");
    }
    if (fp == NULL) {
	perror(filterstr == NULL ? arg : filterstr);
	exit(1);
    }
    return fp;
}

/*
 * End of input; mark end node and close the input stream.
 */
static void finish(FILE *fp)
{
    insert_pair(prev_code, (NODE *)0);
    prev_code = NULL;

    if (filterstr == NULL)
	fclose(fp);
    else
	pclose(fp);
}

/*
 * Ouput text, wrapping as needed.
 */
static void output_word(const char *word)
{
    static char line[MARGIN + 1];
    static int room = MARGIN;
    int l;

    if (word == NULL)
	return;

    l = strlen(word);
    /* If word won't fit, or starts with \n, dump the current line */
    if (line[0] && (l >= room || word[0] == '\n')) {
	printf("%s\n", line);
	line[0] = 0;
	room = MARGIN;
    }

    /* If word won't fit in the buffer or starts with \n, print it now */
    if (l >= MARGIN || word[0] == '\n')
	printf("%s", word);
    else {
	/* Otherwise fill it in */
	strcat(line, word);
	strcat(line, " ");
	room -= (l + 1);
    }
}

/*
 * Generate an article by traversing the structure we've built.
 */
static void generate_article(void)
{
    FOLLOW *p;
    const char *tp;
    int ncounts = num_files;
    int n;
    int accum;

    for (p = start; ; p = p->node->following) {
	/* Roll the dice to find out the next token; select the next token,
	 * and the new state, with a probability corresponding to the
	 * frequency in the input. */
	n = arc4random_uniform(ncounts);
	for (accum = p->count; accum <= n && p->next != NULL; accum += p->count)
	    p = p->next;
	if (p->node == NULL)
	    break;

	/* Check for "end of story" */
	tp = p->node->text2;
	if (tp == NULL)
	    break;
	output_word(tp);
	ncounts = p->node->count;
    }

    /* This flushes the buffer as well. */
    output_word("\n");
}

static void parse(FILE *fp)
{
    char word[256];
    char *p = word;
    int count;
    int c;

    while ((c = getc(fp)) != EOF) {
	if (isspace(c)) {
	    /* Whitespace. Did we have a word? */
	    if (p > word) {
		*p = '\0';
		process_token(word);
		p = word;
	    }
	    if (c == '\n') {
		/* Multiple newlines? */
		for (count = 1; (c = getc(fp)) == '\n'; count++)
		    continue;
		ungetc(c, fp);
		if (count >= 2)
		    process_token("\n");
	    }
	}
	else if (p < &word[sizeof word])
	    *p++ = c;
    }

    /* Anything pending? */
    if (p > word) {
	*p = '\0';
	process_token(word);
    }
}

int main(int argc, char **argv)
{
    int i;
    int count = 10;
    FILE *fp;

    /* Parse options. */
    while ((i = getopt(argc, argv, "f:n:v")) != EOF) {
	switch (i) {
	case 'f':
	    if (strstr(optarg, "%s") == NULL) {
		fprintf(stderr, "Missing %%s in -f value\n");
		exit(1);
	    }
	    filterstr = optarg;
	    break;
	case 'v':
	    verbose = 1;
	    break;
	case 'n':
	    count = atoi(optarg);
	    break;
	default:
	    fprintf(stderr,
	     "Usage: markov3 [-pv] [-n num_art] [-d dump] files\n");
	    return 1;
	}
    }
    argc -= optind;
    argv += optind;
    if (filterstr != NULL && *argv == NULL) {
	fprintf(stderr, "Can't use -f with stdin\n");
	return 1;
    }

    /* Parse input. */
    num_files = 1;
    if (*argv == NULL) {
	parse(stdin);
	finish(stdin);
    }
    else {
	for ( ; *argv != NULL; argv++) {
	    fp = openit(*argv);
	    parse(fp);
	    finish(fp);
	    num_files++;
	}
    }
    if (verbose)
	fprintf(stderr,
	     "%d files %d tokens (%d different) %d different pairs\n",
	     num_files, num_total, num_tokens, num_pairs);

    /* Generate the articles, separated by form feeds */
    for (i = 0; i < count; i++) {
	if (i > 0)
	    output_word("\n\f\n");
	generate_article();
    }
    return 0;
}
