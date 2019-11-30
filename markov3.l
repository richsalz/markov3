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

#define MARGIN 75

typedef struct htentry HTENTRY;
typedef struct node NODE;
typedef struct succnode SUCCNODE;

NODE *insert_token(char *txt, char *txt2);
char *savetoken(const char *);
int my_strcmp(const char *a, const char *b);
void dump_database(char *file);
void generate_article(void);
void insert_pair(NODE *p1, NODE *p2);
void output_word(const char *word);
void process_token(const char *txt);

static int in_included_text = 0;

%}

%Start HDR BODY SIG

%%

<HDR>^[^ \t]+:.*\n	;	/* Header line, e.g. "From: foo@bar.UUCP" */

<HDR>^[ \t]+[^ \t].*\n	;	/* Continuation of header line */

<HDR>^[ \t]*$		BEGIN BODY;
<HDR>.			;	/* Eat anything that escaped */
<HDR>\n			;

<BODY>^[><)|#}].*\n	{
	/* 50% rule gets people to change ">" to other characters;
	 * this gets most of them */
	if (!in_included_text) {
	    in_included_text = 1;
	    process_token("\n> ...\n\n");
	}
    }
<BODY>"]".*\n 		{
    /* should have been included in the above.  My lex generates bad
     * C code if I say [[><...] even though ed(1) says that's a valid
     * regular expression. */
    if (!in_included_text) {
	in_included_text = 1;
	process_token("\n> ...\n\n");
    }
}
<BODY>^"In article".*\n	;	/* Reject rn crud */
<BODY>[ \t]+		;	/* Skip white space */
<BODY>\n[ \t\n]*\n	{
    /* Paragraph break */
    process_token("\n");
}
<BODY>[^ \t\n]+		{
    in_included_text = 0;
    process_token(yytext);
}
<BODY>\n		;

<SIG>.			;
<SIG>\n			;

%%

/*
 * hashtab is a hash table storing all the tokens we encounter.
 */

struct htentry {
    char *htext;
    HTENTRY *hlink;
};

#define HSIZE 3557		/* Should be prime */

HTENTRY hashtab[HSIZE];

/*
 * node and succnode are portions of the big structure we're going to build.
 * node represents something like ("was", "a") in a binary tree.
 * a linked list of succnodes contain tokens that may follow ("was", "a")
 */
struct node {
    char *text;
    char *text2;
    int ocount;
    NODE *lc, *rc;
    SUCCNODE *succ;
};

struct succnode {
    NODE *scnod;
    int    count;
    SUCCNODE *link;
};


NODE *prev_code;
NODE *root;
NODE *tknptr;
SUCCNODE *start;
char **Argv;
char *prev_token;
int init_state = HDR;
int n_files;
int n_pairs;
int n_tokens;
int n_total;
int verbose;

/*
 * We have a new token.  Say the previous two tokens were "one" "way"
 * and the current token is "to".  Then prev_code points to a node
 * for ("one", "way") and token is "to".  This function adds ("way", "to") as a
 * successor to ("one","way") and makes prev_code point to ("way","to").
 */
void process_token(const char *txt)
{
     char *token = savetoken(txt);
     NODE *code = insert_token(prev_token, token);

     insert_pair(prev_code, code);
     prev_code = code;
     prev_token = token;
}

int main(int argc, char **argv)
{
    int i;
    int c;
    int n_articles = 10;
    char *dumpfile = NULL;

    while ((c = getopt(argc, argv, "vpn:d:")) != EOF) {
	switch (c) {
	case 'v':
	    verbose = 1;
	    break;
	case 'p':		/* Input is plain text, not Usenet stuff */
	    init_state = BODY;
	    break;
	case 'n': 		/* # articles to generate */
	    n_articles = atoi(optarg);
	    break;
	case 'd':		/* where to dump the data structure */
	    dumpfile = optarg;
	    break;
	default:
	    fprintf(stderr,
	     "Usage: markov3 [-pv] [-n n_art] [-d dump] files\n");
	    return 1;
	}
    }
    argc -= optind;
    argv += optind;

    /* initial state of lexical analyzer */
    BEGIN init_state;

    /* yyin is lex input stream.  Point to first file. */
    if (argv[0] != NULL) {
	if ((yyin = fopen(*argv, "r")) == NULL) {
	    perror(*argv);
	    return 1;
	}
	argv++;
    }
    /* make it global so yywrap can access it */
    Argv = argv;
    n_files = 1;

    /* Parse input, build the database. */
    yylex();
    if (dumpfile)
	dump_database(dumpfile);
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

/*
 * Lex calls this when EOF is reached.  It opens the next file if there
 * is one.  Lex interprets a return value of 1 to mean "all done" and 0
 * to mean "keep going".
 */
int yywrap(void)
{
    fclose (yyin);
    insert_pair(prev_code, (NODE *)0);
    prev_code = NULL;
    if (*Argv == NULL)
	return 1;
    if ((yyin = fopen(*Argv, "r")) == NULL) {
	perror(*Argv);
	exit(1);
    }

    Argv++;
    in_included_text = 0;
    if (verbose && n_files % 10 == 0)
	fprintf (stderr, "%d files\n", n_files);
    n_files++;
    BEGIN init_state;
    return 0;
}

/*
 * This function saves a token in the hash table (if it isn't there
 * already) and returns a pointer to the stored copy.
 */
char *savetoken(const char *txt)
{
    int h;
    const char *p;
    HTENTRY *hp;

    n_total++;
    for (p = txt, h = 0; *p; h += *p++)
	continue;

    for (hp = hashtab + (h % HSIZE); hp->hlink; hp = hp->hlink) {
	if (strcmp (hp->htext, txt) == 0) {
	    return hp->htext;
	}
    }
    /* OK, it's a new token.  Make hp->hlink point to a new,
     * null block and make hp->htext point to the text.
     */
    n_tokens++;
    hp->hlink = (HTENTRY *)malloc(sizeof (*hp));
    hp->htext = strdup(txt);
    hp->hlink->hlink = NULL;
    hp->hlink->htext = NULL;
    return hp->htext;
}

/*
 * This recursive function inserts a token pair into the tree.
 */
NODE *insert_in_tree(NODE *p, char *txt, char *txt2)
{
    int cmp;

    if (p == NULL) {
	/* Create a new node. */
	p = (NODE *)malloc(sizeof (*p));
	p->text = txt;
	p->text2 = txt2;
	p->lc = p->rc = NULL;
	p->succ = NULL;
	p->ocount = 1;
	tknptr = p;
	n_pairs++;
	if (verbose && n_pairs % 1000 == 0)
	    fprintf(stderr, "%d pairs\n", n_pairs);
	return p;
    }

    cmp = my_strcmp(p->text, txt);
    if (cmp == 0)
	cmp = my_strcmp (p->text2, txt2);

    if (cmp == 0) {
	/* It's a match.  Increment the count. */
        tknptr = p;
	p->ocount += 1;
    }
    /* Look in the subtrees. */
    else if (cmp < 0)
	p->lc = insert_in_tree(p->lc, txt, txt2);
    else
	p->rc = insert_in_tree(p->rc, txt, txt2);
    return p;
}

/*
 * This just calls insert_in_tree starting at the root
 */
NODE *insert_token(char *txt, char *txt2)
{
    root = insert_in_tree(root, txt, txt2);
    return tknptr;
}

/*
 * This function adds a successor.
 */
SUCCNODE *insert_in_succ_chain(SUCCNODE *sp, NODE *np)
{
    if (sp == NULL) {
	sp = (SUCCNODE *)malloc(sizeof (*sp));
	sp->scnod = np;
	sp->count = 1;
	sp->link = NULL;
    }
    else if (sp->scnod == np)
	sp->count += 1;
    else
	sp->link = insert_in_succ_chain(sp->link, np);
    return sp;
}

/*
 * This calls insert_in_succ_chain starting at the right place.
 */
void insert_pair(NODE *p1, NODE *p2)
{
    if (p1)
	p1->succ = insert_in_succ_chain (p1->succ, p2);
    else
	start = insert_in_succ_chain (start, p2);
}

/*
 * This function dumps the stored data structure onto a file.
 * Now if only I had a function to read it back in.
 */
char *pr_token(char *txt)
{
    if (txt[0] != '\n')
	return txt;
    return txt[1] ? "<INCL>" : "<LF>";
}

/*
 * Subroutine of treedump; it does one row.
 */
void chaindump(SUCCNODE *p, FILE *fp)
{
    char *text;

    for ( ; p != NULL; p = p->link) {
	if (p->scnod == NULL)
	    text = "<EOF>";
	else
	    text = pr_token(p->scnod->text2);
	fprintf (fp, " %s %d", text, p->count);
    }
    putc('\n', fp);
}

void treedump(NODE *tree, FILE *fp)
{
    if (tree != NULL) {
	treedump(tree->rc, fp);
	fprintf(fp, "( %s %s ) %d",
	    pr_token(tree->text), pr_token (tree->text2),
	    tree->ocount);
	chaindump(tree->succ, fp);
	treedump(tree->lc, fp);
    }
}

/*
 * This routine generates the dump file (-d option)
 */
void dump_database(char *file)
{
    FILE *fp = fopen (file, "w");

    if (fp == NULL) {
	perror(file);
	exit(1);
    }
    fprintf(fp, "START:");
    chaindump(start, fp);
    treedump(root, fp);
    fclose(fp);
}

/*
 * This function generates an article by traversing the
 * structure we've built.
 */
void generate_article(void)
{
    SUCCNODE *p = start;
    int ncounts = n_files;
    int n;
    int accum;
    char *tp;

    while (1) {
	/* Roll the dice to find out the next token.  The code below selects
	 * the next token, and the new state, with a probability corresponding
	 * to the frequency in the input. */
	n = arc4random_uniform(ncounts);
	for (accum = p->count; accum <= n && p->link; accum += p->count)
	    p = p->link;
	if (p->scnod == NULL)
	    break;

	/* Check for "end of story" */
	tp = p->scnod->text2;
	if (tp == NULL)
	    break;
	output_word(tp);
	ncounts = p->scnod->ocount;
	p = p->scnod->succ;
    }
    /* This will flush the buffer as well. */
    output_word("\n");
}

/*
 * This version handles null strings *
 */
int my_strcmp (const char *a, const char *b)
{
    if (a == NULL)
	return b ? -1 : 0;
    if (b == NULL)
	return 1;
    return strcmp (a, b);
}

void output_word(const char *word)
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
	printf ("%s", word);
    /* Otherwise fill it in */
    else {
	strcat(line, word);
	strcat(line, " ");
	room -= (l + 1);
    }
}
