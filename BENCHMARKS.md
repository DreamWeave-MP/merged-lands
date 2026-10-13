# Merged Lands benchmarks

`bench/bench.luau` times the merge through `@merged-lands`, the way a tool reaches it: a load
order on disk in, its plugin on disk out. The load order is synthetic and the same every run: a
master of 100 cells of rolling ground, and three plugins over it, 30, 36, and 36 cells, that
raise, repaint, and lower overlapping parts of it, so that heights, normals, colors, textures,
and world maps all conflict, and a ridge ends on a cell border for the seams to repair. It is
merged alone, by load order, with every part under `Resolve`, and with every part under `Ignore`.
Each workload is warmed up, sized to a batch of about a tenth of a second, and reported as the
median of seven batches with a full collection between them. Every workload's report and the
SHA-256 of its plugin, less the description that holds the time of the run, are checked against
what the merge wrote before any of the changes below, so a path that stopped doing the work, or
does it differently, stops the bench.

```sh
jess run --package jpk/merged-lands --package-path jpk \
  --capability filesystem.read --capability filesystem.write \
  jpk/merged-lands/bench/bench.luau <scratch folder> [filter]
```

A merge's time is not all this package's. Reading a LAND as buffers and writing one back are
`@tes3`'s, opening the plugins is `@load-order`'s, and they were held fixed here: of the 10 ms
the master alone now takes, about 3 ms is `tes3.land.read`, and of the 49 ms by load order about
8 ms is `tes3.land.read` and 10 ms `tes3.land.write`.

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-13.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides, and the same sibling packages.
- Base: `95f76b1`, the package before the move, with this bench and the tests that pin it.
  Head: `5cc9cf5`.
- Protocol: the whole bench run against base, then head, five times over, back to back under one
  lock; each cell is the median of its five runs. A difference under 5 percent is called no
  change.

| Workload | Base, ms | Head, ms | Base / head |
|---|---:|---:|---:|
| merge a master of 100 cells alone | 17.50 | 10.22 | 1.71x |
| merge three plugins over it, by load order | 110.17 | 49.03 | 2.25x |
| merge three plugins over it, by Resolve | 507.75 | 199.49 | 2.55x |
| merge three plugins over it, by Ignore | 144.42 | 79.08 | 1.83x |

An earlier run of the same A/B at the same source gave 1.64x, 2.12x, 2.62x, and 1.86x.

The whole command, cold, as `src/main.luau` run once per process over the same load order
(median of 15 runs each, alternating): 342 ms against 345 ms for the master alone, no change,
since starting Jess and loading the packages is nearly all of it; 435 ms against 380 ms by load
order, 1.15x.

### What moved, commit by commit

Each commit below against its parent, three rounds, same protocol. Rows not named did not move.

| Commit | What it does | Moved |
|---|---|---|
| `d8ca0a9` | Two buffers compare with `bytes.equals`, not as the strings of their bytes | master alone 1.26x, load order 1.10x |
| `7ed40b2` | Heights merge an i32 at a time and normals and colors three bytes at a time, in loops of their own | load order 1.77x, Resolve 1.45x, Ignore 1.37x |
| `92ce32e` | A Resolve keeps the average of each pair of bytes it has met | Resolve 1.72x |
| `f4934b6` | Normals are masked a row at a time, and `anyEq` on the data plane says first whether there is anything to mask | master alone 1.14x |
| `4dcaf6d` | A cell's sides are taken with `data.gather` and put back with `data.scatter` | master alone 1.19x, Ignore 1.05x |
| `387c161` | The inside of a cell is compared a row at a time with `bytes.compare` | nothing: 1.10x by load order on a first reading, which three and then seven more rounds did not repeat |
| `74c1d56` | A written cell keeps the normal of each pair of whole slopes it has met | load order 1.13x, Ignore 1.16x |

The comprehensions, reducers, record patterns, and the slice (`b802ff0`, `075f6f2`, `331dfe9`)
are in code that runs once a merge or once a cell, and moved nothing that repeats: a three-round
run read 1.08x on one row and another 1.06x on a different one, never the same row twice.

### What moved, and why

The time was in three places. The merge compared whole buffers by making a string of each, 17 KB
of allocation and hashing a side where `bytes.equals` is one `memcmp` (5.7 µs to 0.27 µs for a
LAND's heights); that is every LAND of every plugin, and most of what the master alone gained.
The three merges, overwrite, ignore, and resolve, walked every vertex through one loop for every
kind of part, which asked the kind its size at each element and copied each changed one with a
call to `buffer.copy`: about 29 ns a vertex, against 4 to 6 ns once heights and three-byte parts
each have a loop that reads and writes them directly. And a Resolve worked its weighted average
out, two `pow`s and nine roundings to f32, for every component of every conflicting normal and
color, 1.4 million times in this load order: a byte against a byte has 65,536 answers, so each
kind now keeps the ones it has met, and 13,000 of them were all it needed. Normals from heights
got the same treatment for written cells, keyed on the two slopes a normal depends on.

The data plane does what it is good at here and no more. It moves a cell's 260 side vertices by
index (`gather`, `scatter`: 7.6 µs to 2.1 µs for a side's normals, 1.7 µs to 1.0 µs for its
heights), and it answers "is any height 0" in one native pass (16.7 µs to 4.4 µs through the
typed receiver, 8.4 µs through `data.any`), which lets a master's cells skip masking altogether.
It was tried for the merges themselves and lost: a conditional copy of changed heights as
`scale`, `add`, `compare` into a selection, `indices`, `gather`, `scatter` took 35 µs a part
against 16 µs for the plain loop over two buffers, and 81 µs against 24 µs for three-byte parts,
because the plane compares a span against a number, not against another span, so the difference
has to be made first. Turning a LAND's steps into heights with `fill`, `add`, and `scale`
measured 18.1 µs against the loop's 19.8 µs, inside the noise, and stayed a loop; written as a
typed sink over a typed slice it was slower (the master alone at 0.92x) and was put back.

What is left in this package is mostly that loop, 2 ms of the master's 10 ms, the merges
themselves, and the heights a Resolve averages, whose pairs are too many to keep.
