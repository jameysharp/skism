# skism: An interpreter for SKI combinators in WebAssembly

This is an interpreter for an [esoteric programming language][], the
[SKI combinator calculus][]. I've chosen to write it in
[WebAssembly][]'s text format, "[wat][]", as an exercise. For fun,
theoretically.

[esoteric programming language]: https://en.wikipedia.org/wiki/Esoteric_programming_language
[SKI combinator calculus]: https://en.wikipedia.org/wiki/SKI_combinator_calculus
[WebAssembly]: https://webassembly.org/
[wat]: https://webassembly.github.io/spec/core/text/index.html

## Acknowledgements

I wouldn't have started on this particular adventure without the
encouragement of my friend, [MonoidMusician][], who proposed the initial
problem description and answered so many questions for me about how this
is supposed to work. And while the result may not, technically, be
"useful", I learned a lot and had a good time. Thank you friend!

[MonoidMusician]: https://blog.veritates.love/

They were in turn inspired by [Jot][], invented as "[a better Gödel
numbering][jot-paper]", and an interesting topic in its own right.

[Jot]: https://esolangs.org/wiki/Jot
[jot-paper]: https://web.archive.org/web/20201112014512/http://www.nyu.edu/projects/barker/Iota/

## Input language

SKI combinator programs consist exclusively of operators named "S", "K",
and "I", which is where the name comes from. This interpreter has one
more non-standard operator, which I've named "P".

In the following description I'll use lowercase letters x/y/z to
represent any valid program: either an I/K/S by itself, or Pxy. The
lowercase letters are not valid syntax in this language.

"I" takes one argument and returns it unchanged; it's the "identity"
function.

"K" takes two arguments and returns the first, discarding the second.

"S" takes three arguments&mdash;let's call them x, y, and z&mdash;and
applies x to z, and applies y to z, and finally applies the first to the
second. In short, it's equivalent to `xz(yz)`.

If one of these operators doesn't have enough arguments available, then
it is not "reducible" and appears as itself in the output. This is the
only form of output that my interpreter supports.

These programs can always be written as a binary tree, with the
arguments applied one at a time by [currying][]. So for example, `Sxyz`
is equivalent to `(((Sx)y)z)`.

[currying]: https://en.wikipedia.org/wiki/Currying

"P" (short for "push" or "parentheses", perhaps) is a prefix operator
used instead of parentheses. `Pxy` is like `(xy)`, so instead of writing
`(((Sx)y)z`, write `PPPSxyz`.

These four letters, S/K/I/P, are the only valid characters in this
language.

I chose "P" for the extra operator name for several important reasons:

- It's mnemonically appropriate.
- It isn't one of the existing "[combinator birds][]", shorthands for
  various useful patterns of the basic SKI combinators.
- It let me do a terrible hack in the input parser; choosing "E" or "H"
  instead would have let me save one more instruction but this was silly
  enough already.
- It allows writing programs like "PSPSPSS", as if you're talking to a
  cat.

[combinator birds]: https://www.angelfire.com/tx4/cus/combinator/birds.html

## Interpreter usage

I was kinda focused on writing the interpreter and didn't give it a
convenient interface yet. At the moment, I've embedded the module for
the interpreter inside a "[wast][]" test, which is the format used for
tests in the official WebAssembly specification test suite. 

[wast]: https://github.com/WebAssembly/spec/tree/main/interpreter#scripts

I tested this program using [Wasmtime][], like so:

```sh
wasmtime wast test.wast
```

[Wasmtime]: https://wasmtime.dev/

If any of the test cases fail, this will print an incomprehensible stack
trace. Good luck.
