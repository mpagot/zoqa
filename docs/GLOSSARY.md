# zoqa

The vocabulary of `zoqa`, a client for the openQA test infrastructure. These
terms mean what this project's documentation means by them; where the wider
openQA project uses a word differently, the entry says so.

## Language

### Server concepts

**Job**:
One execution of a **scenario**, identified by a numeric ID that `zoqa` takes
as input or prints as output. A **job** has a lifecycle state and a final
result, and carries its **job settings** and **assets**.
_Avoid_: test run, task

**Job setting**:
A `KEY=VALUE` pair attached to a **job** that configures what it does
(`DISTRI`, `VERSION`, `ARCH`, `BUILD`, `MACHINE`). **Settings** or **openQA
settings**, unqualified, always means these; **environment variable** is the OS
concept, and *variable* alone belongs to source code.
_Avoid_: variable, parameter, config key

**Job group**:
An organisational container in the openQA web UI that groups related **job
templates** and governs their visibility and retention. `zoqa` meets a **job
group** only as the `_GROUP_ID` **job setting**.
_Avoid_: category, project

**Job template**:
A server-side definition that combines a product, a test suite and a machine
into executable jobs; a **scheduled product** expands templates into **jobs**.
`zoqa` does not manage templates — `schedule` supplies the **job settings**
that templates match on.
_Avoid_: definition, scenario

**Scenario**:
The combination of a product, a test suite and a machine that a **job template**
encodes and that a **job** executes. Scheduling a **scenario** creates one or
more **jobs**.
_Avoid_: test case, combination

**Scheduled product**:
The server-side record of one product, such as one ISO build, submitted for
testing, identified by `scheduled_product_id`. `zoqa schedule --monitor` waits
on a **scheduled product** until it has created its **jobs**.
_Avoid_: ISO post, product build

**Test module**:
One module of test code inside a **job**, named in the job's `testresults` and
run in sequence with the others. `zoqa archive` writes one `details-<name>.json`
file per **test module**.
_Avoid_: test step, test case

### Artifacts

**Asset**:
A file the server distributes to workers so a **job** can run — installation
ISOs, disk images, repositories. **Assets** are stored on the server under
`factory/` and grouped by **asset type**.
_Avoid_: file, attachment

**Asset type**:
The category of an **asset**, which selects the server route and the local
subdirectory: `iso`, `hdd`, `repo`, `other`. `repo` is the one type that both
cloning and archiving skip.
_Avoid_: asset kind, asset class

**Screenshot**:
An image captured from the system under test at a point in time and stored
under the **job**'s results, addressed on the server by an md5-derived
directory. `zoqa archive` downloads the **screenshots** referenced by each
**test module**'s details.
_Avoid_: capture, frame

**Log**:
A diagnostic text file produced by the **job** or its worker, listed in the
job's `logs` and served from `/tests/{id}/file/`. A **log** comes from the
harness; a **ulog** comes from inside the system under test.
_Avoid_: output, console dump

**Ulog**:
A file uploaded from inside the system under test during a **test module**
run, such as a crash dump or an in-guest log, listed separately in the job's
`ulogs` and stored under `ulogs/`.
_Avoid_: guest log, user log

**Generated asset**:
An **asset** that a **parent** job produces during its own run and publishes
(`PUBLISH_HDD_*`, `PUBLISH_PFLASH_VARS`), rather than one an operator supplies.
Cloning does not download a **generated asset** when the publishing **parent**
is part of the clone.
_Avoid_: output asset, built asset

### Job graph

**Parent**:
A **job** that another **job** depends on through a **chained**, **directly
chained** or **parallel dependency**. Cloning traverses parents by default,
unless `--skip-deps` or `--skip-chained-deps` is given.
_Avoid_: prerequisite, upstream job

**Child**:
A **job** that depends on a **parent**. Cloning follows only parallel children
unless `--clone-children` is given.
_Avoid_: dependent job, downstream job

**Chained dependency**:
A **parent**/**child** relation in which the child runs only after the parent
has finished successfully; declared with `START_AFTER_TEST` and encoded on the
clone as `_START_AFTER`.
_Avoid_: sequential dependency, ordered dependency

**Directly chained dependency**:
A **chained dependency** that additionally requires the child to run
immediately after the parent on the same worker; declared with
`START_DIRECTLY_AFTER_TEST` and encoded on the clone as `_START_DIRECTLY_AFTER`.
_Avoid_: immediate dependency, direct chain

**Parallel dependency**:
A **parent**/**child** relation in which both jobs must run at the same time,
typically a cluster with a coordinating server; declared with `PARALLEL_WITH`
and encoded on the clone as `_PARALLEL`. Cloning traverses parallel parents
always, and parallel children by default.
_Avoid_: concurrent job, sibling

**Clone**:
A new **job** created on the destination instance from the **job settings** of
an existing job, with the dependency settings re-encoded for the new IDs. A
**clone** is a job, not a copy of the **asset** files.
_Avoid_: copy, duplicate, re-run

**Dependency graph**:
The set of **parent** and **child** jobs reachable from one root job, walked
breadth-first during cloning. The graph encoded on the clone is a subset:
parents skipped by `--skip-*` are dropped from the outgoing settings.
_Avoid_: clone graph, job graph, module graph

### Client vocabulary

**Within-instance**:
A cloning mode in which the source and the destination are the same openQA
instance (`--within-instance HOST`), shorthand for `--from HOST --host HOST
--skip-download`. It suppresses asset downloads because the server already has
them.
_Avoid_: same-host clone

**Source instance / destination instance**:
The **source instance** hosts the **job** being cloned (`--from`, or the host
part of a job URL); the **destination instance** receives the new **jobs**
(`--host`). Credentials are resolved per host, so the two authenticate
independently.
_Avoid_: origin server, target server, remote, local

**Follow**:
A request modifier (`--follow`, `?follow=1`) that asks the server to report the
status of the newest **clone** of a **job** instead of the original. It affects
`monitor`, and `schedule` only together with `--monitor`.
_Avoid_: watch, track

**Terminal state**:
A **job** state from which no further transitions occur — `done` or
`cancelled`. Monitoring ends when every job is in a **terminal state**; the
final result then decides the exit code.
_Avoid_: finished, completed, final state

**Override**:
A `KEY[:SCOPE][+]=VALUE` argument that changes a **job setting** on the clone:
plain assignment, `:SCOPE` to target one **test module**, `+` to append, and an
empty value to delete. An **override** reaches the root job and any cloned
**children**, but not **parents**, unless `--parental-inheritance` is given.
_Avoid_: parameter, setting flag

**Oracle**:
The upstream Perl implementation, `openqa-cli` and `openqa-clone-job`, whose
observable behaviour defines what `zoqa` must match. Where the **oracle** is
wrong, the difference is a **deviation**, and it is recorded as one.
_Avoid_: reference client, baseline tool

**Parity**:
Agreement between `zoqa` and the **oracle** in everything a user can observe:
output, exit codes, files on disk, requests sent. **Parity** is the default
requirement; every exception is a **deviation**.
_Avoid_: compatibility, equivalence

**Deviation**:
A place where `zoqa` knowingly behaves differently from the **oracle**, with
the difference and its reason recorded in
[PERL_DEVIATIONS.md](./PERL_DEVIATIONS.md). A **deviation** exists only where
**parity** was possible and was deliberately rejected; anything else is a bug
or a gap.
_Avoid_: divergence, difference
