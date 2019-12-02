%{
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
#include <assert.h>

#define MARGIN 75
#define HSIZE 3557		/* Should be prime */

typedef struct htentry HTENTRY;
typedef struct node NODE;
typedef struct follow FOLLOW;

static void process_token(const char *txt);

static int in_included_text = 0;

%}

%%

^[[	><)|#}].*\n {
	/* Try to catch most quoted text, email and Usenet. */
	if (!in_included_text) {
	    in_included_text = 1;
	    process_token("\n> ...\n\n");
	}
}
\n\n+	{
	/* Paragraph break */
	process_token("\n");
}
[^ \t\n]+	{
	in_included_text = 0;
	process_token(yytext);
}
[\n \t]		;	/* Skip white space */

%%

/*
 * hashtab is a hash table storing all the tokens we encounter.
 */
struct htentry {
    char *text;
    HTENTRY *next;
};
HTENTRY hashtab[HSIZE];

/*
 * node and follow are portions of the structure we're going to build. A
 * node represents something like ("was", "a") in a binary tree.
 * a linked list of follow's contain tokens that may follow ("was", "a")
 */
struct node {
    const char *text;
    const char *text2;
    int ocount;
    NODE *left;
    NODE *right;
    FOLLOW *following;
};

struct follow {
    int count;
    NODE *node;
    FOLLOW *next;
};


static NODE *prev_code;
static NODE *root;
static NODE *tknptr;
static FOLLOW *start;
static char **Argv;
static const char *filterstr;
static char *prev_token;
static int n_files;
static int n_pairs;
static int n_tokens;
static int n_total;
static int verbose;

/*
 * This function saves a token in the hash table (if it isn't there
 * already) and returns a pointer to the stored copy.
 */
static char *savetoken(const char *txt)
{
    int h;
    const char *p;
    HTENTRY *hp;

    n_total++;
    for (p = txt, h = 0; *p; h += *p++)
	continue;

    for (hp = &hashtab[h % HSIZE]; hp->next != NULL; hp = hp->next) {
	if (strcmp(hp->text, txt) == 0)
	    return hp->text;
    }

    /* OK, it's a new token.  Make hp->next point to a new,
     * null block and make hp->text point to the text.
     */
    n_tokens++;
    hp->text = strdup(txt);
    hp->next = (HTENTRY *)malloc(sizeof (*hp));
    hp->next->next = NULL;
    hp->next->text = NULL;
    return hp->text;
}

/*
 * This version handles null strings
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
 * This recursive function inserts a token pair into the tree.
 */
static NODE *insert_in_tree(NODE *p, char *txt, char *txt2)
{
    int cmp;

    if (p == NULL) {
	/* Create a new node. */
	p = (NODE *)malloc(sizeof (*p));
	p->text = txt;
	p->text2 = txt2;
	p->left = p->right = NULL;
	p->following = NULL;
	p->ocount = 1;
	tknptr = p;
	n_pairs++;
	if (verbose && (n_pairs % 1000) == 0)
	    fprintf(stderr, "%d pairs\n", n_pairs);
	return p;
    }

    cmp = my_strcmp(p->text, txt);
    if (cmp == 0)
	cmp = my_strcmp(p->text2, txt2);

    if (cmp == 0) {
	/* It's a match.  Increment the count. */
        tknptr = p;
	p->ocount += 1;
    }
    /* Look in the subtrees. */
    else if (cmp < 0)
	p->left = insert_in_tree(p->left, txt, txt2);
    else
	p->right = insert_in_tree(p->right, txt, txt2);
    return p;
}

/*
 * This just calls insert_in_tree starting at the root
 */
static NODE *insert_token(char *txt, char *txt2)
{
    root = insert_in_tree(root, txt, txt2);
    return tknptr;
}

/*
 * This function adds a successor.
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
 * This calls insert_in_succ_chain starting at the right place.
 */
void insert_pair(NODE *p1, NODE *p2)
{
    if (p1)
	p1->following = insert_in_succ_chain(p1->following, p2);
    else
	start = insert_in_succ_chain(start, p2);
}


/*
 * We have a new token.  Say the previous two tokens were "one" "way"
 * and the current token is "to".  Then prev_code points to a node
 * for ("one", "way") and token is "to".  This function adds ("way", "to") as a
 * successor to ("one","way") and makes prev_code point to ("way","to").
 */
static void process_token(const char *txt)
{
     char *token = savetoken(txt);
     NODE *code = insert_token(prev_token, token);

     insert_pair(prev_code, code);
     prev_code = code;
     prev_token = token;
}

static void openit(const char *arg)
{
    char buff[256];

    if (filterstr == NULL)
	yyin = fopen(arg, "r");
    else {
	snprintf(buff, sizeof buff, filterstr, arg);
	yyin = popen(buff, "r");
    }
    if (yyin == NULL) {
	/* gcc -Wall fodder */
	if (arg == NULL)
	    yyunput(0, NULL);
	perror(filterstr == NULL ? arg : filterstr);
	exit(1);
    }
}

/*
 * Lex calls this when EOF is reached.  It opens the next file if there
 * is one.  Lex interprets a return value of 1 to mean "all done" and 0
 * to mean "keep going".
 */
int yywrap(void)
{
    insert_pair(prev_code, (NODE *)0);
    prev_code = NULL;

    if (filterstr == NULL)
	fclose(yyin);
    else
	pclose(yyin);
    if (*Argv == NULL)
	return 1;

    openit(*Argv++);
    in_included_text = 0;
    if (verbose && n_files % 10 == 0)
	fprintf(stderr, "%d files\n", n_files);
    n_files++;
    return 0;
}

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
 * This function generates an article by traversing the
 * structure we've built.
 */
static void generate_article(void)
{
    FOLLOW *p;
    const char *tp;
    int ncounts = n_files;
    int n;
    int accum;

    for (p = start; ; p = p->node->following) {
	/* Roll the dice to find out the next token.  The code below selects
	 * the next token, and the new state, with a probability corresponding
	 * to the frequency in the input. */
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
	ncounts = p->node->ocount;
    }
    /* This will flush the buffer as well. */
    output_word("\n");
}

int main(int argc, char **argv)
{
    int i;
    int c;
    int n_articles = 10;

    while ((c = getopt(argc, argv, "f:n:v")) != EOF) {
	switch (c) {
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
	case 'n': 		/* # articles to generate */
	    n_articles = atoi(optarg);
	    break;
	default:
	    fprintf(stderr,
	     "Usage: markov3 [-pv] [-n n_art] [-d dump] files\n");
	    return 1;
	}
    }
    argc -= optind;
    argv += optind;

    /* yyin is lex input stream.  Point to first file. */
    if (argv[0] != NULL)
	openit(*argv++);
    Argv = argv;
    n_files = 1;

    /* Parse input, build the database. */
    yylex();
    if (verbose)
	fprintf(stderr,
	     "%d tokens (%d different), %d different pairs, %d files\n",
	     n_total, n_tokens, n_pairs, n_files);

    /* Generate the articles, separated by form feeds */
    for (i = 0; i < n_articles; i++) {
	if (i > 0)
	    output_word("\n\f\n");
	generate_article();
    }
    return 0;
}
