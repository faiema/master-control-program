# AGENTS.md

## Project

**master-control-program**

The project name deliberately misinterprets **MCP** as **Master Control Program**, in reference to *TRON*.

Technically, this repository implements tools using the **Model Context Protocol**. Keep the joke in the project identity, but use the correct protocol terminology where ambiguity would matter.

## Bootstrap status

This file is the initial seed for a new repository.

At project inception it may contain more design context than a mature `AGENTS.md` normally should. As the repository develops, reorganize material into appropriate files such as `README.md`, `docs/architecture.md`, implementation notes, tests, or module-specific documentation.

After moving material elsewhere, keep `AGENTS.md` focused on durable instructions agents need while working in the repository.

Do not preserve an awkward initial structure merely because it appears here. Refactor when useful.

## Purpose

`master-control-program` is a small personal MCP sidecar that complements the official hosted X MCP.

It exists because the official X MCP is already useful for many operations, but the tool surface observed at project inception leaves important gaps for a multimodal ChatGPT workflow.

The connected official X MCP can retrieve things such as:

- authenticated user information;
- posts and timelines;
- post text;
- timestamps;
- conversation relationships;
- public metrics;
- mentions;
- bookmarks;
- media attachment metadata;
- media keys;
- media dimensions;
- direct `pbs.twimg.com` media URLs;
- search and related read operations.

However, in the tool surface actually exposed to us at project inception, it does **not** expose:

1. a way to retrieve attached image bytes so that a vision-capable MCP client can actually inspect the image;
2. media-upload tools suitable for attaching local or generated images to new posts;
3. post-creation tools, despite the underlying X API supporting post creation.

These observations describe the current integration and may change. Re-check live capabilities before building workarounds around an assumption that X has subsequently fixed.

The project should patch missing capabilities rather than gratuitously recreate the entire X API.

## Primary goal

Make workflows such as this possible:

> "Look at my recent X post and tell me what worked about the image."

and:

> "Post this generated image with this text."

without requiring the user to manually shuttle media between ChatGPT and X.

A successful system should let a multimodal agent retrieve an X post, receive the actual attached image as image content, reason about it visually, and perform explicitly requested posting operations.

## Initial MCP surface

Start with the smallest useful set of tools.

### `fetch_x_media`

Retrieve media attached to an X post and return the **actual media content** in a form an MCP client can consume.

For images, the important result is image bytes plus the correct MIME type, exposed as MCP image content where supported.

Returning only:

- a media key;
- metadata;
- dimensions; or
- a `pbs.twimg.com` URL

does **not** satisfy the purpose of this tool.

The agent must actually be able to see the image.

Useful input forms may include:

- X post ID;
- media key;
- direct X media URL.

Choose the cleanest interface supported by the implementation.

Image support is the first priority. Video and other media may be added later when there is a concrete need.

### `upload_x_media`

Upload media through the official X API and return whatever stable identifier is required to attach that media to a post.

Support images first.

Design the interface around real MCP client capabilities rather than inventing an awkward abstraction prematurely.

### `create_x_post`

Create an X post through the official X API.

Initial useful capabilities:

- text-only post;
- post with previously uploaded media;
- optional reply target when straightforward.

Later capabilities may include:

- quoting;
- threads;
- richer reply workflows;
- other X-supported post features.

Do not add complexity before a real workflow requires it.

## Relationship to the official X MCP

The official hosted X MCP remains useful.

Prefer composition over replacement.

A likely architecture is:

```text
ChatGPT / MCP client
    |
    +-- official X MCP
    |     reads
    |     timelines
    |     search
    |     mentions
    |     bookmarks
    |     metrics
    |     other capabilities it already exposes well
    |
    +-- master-control-program
          fetch actual media bytes
          upload media
          create posts
          other narrowly justified missing operations
```

Do not duplicate an official X MCP capability merely for symmetry.

Duplication is justified when:

- the official capability cannot satisfy the actual workflow;
- the official capability is unavailable to our client;
- combining an operation locally produces a meaningfully better interface;
- caching, archival work, or analysis later creates a concrete reason.

If replacing more of the official MCP eventually becomes simpler than maintaining two integrations, reassess deliberately rather than treating the initial architecture as sacred.

## X API policy

Use the documented official X API.

Do not build this project around:

- scraping authenticated X pages;
- private or reverse-engineered endpoints;
- browser cookies;
- session-token theft;
- undocumented mobile endpoints;
- brittle HTML automation.

If an official API limitation makes a desired feature impossible, document the limitation rather than quietly substituting a fragile workaround.

## Authentication

Use proper X OAuth authentication suitable for actions performed on behalf of the user's own account.

Follow least-privilege principles.

Request only the scopes actually needed for implemented features.

The exact OAuth configuration and scope names must be verified against the current X documentation during implementation. Do not rely permanently on remembered names or old examples.

Authentication code should be isolated from application logic so that changes to X's OAuth implementation do not infect the rest of the project.

## Security

Never commit:

- API keys;
- OAuth client secrets;
- access tokens;
- refresh tokens;
- cookies;
- passwords;
- private signing material;
- other credentials.

Use environment variables, an appropriate local secret store, or another clearly documented secure mechanism.

Do not print credentials in normal logs.

Do not include real secrets in fixtures, examples, screenshots, documentation, or tests.

Do not expose tokens through MCP tool results.

Treat URLs containing temporary credentials or signatures as sensitive where applicable.

## Write safety

Posting to X is a real external side effect.

A read or analysis operation must never publish anything.

A tool that creates, replies to, quotes, deletes, likes, follows, uploads, or otherwise mutates X state should be clearly represented as a write operation.

Do not publish posts during ordinary automated tests.

Use mocks, fixtures, dry-run behavior, or a deliberately isolated test account where appropriate.

The user's explicit request to publish should be the reason a live publishing operation occurs.

## Cost awareness

The X API is metered.

Treat unnecessary API calls as a design defect, but do not make the software unpleasant merely to save tiny amounts of money.

Prefer:

- reusing already retrieved data;
- sensible caching where permitted;
- avoiding duplicate media downloads;
- batching where the API naturally supports it;
- avoiding repeated paid reads when local data is sufficient.

Do not hardcode current X prices into business logic. Pricing changes.

If the software presents estimated API costs, keep pricing configuration separate and clearly subject to change.

Before implementing durable storage or caching of X content, verify the current X developer terms and retention rules rather than assuming arbitrary archival rights.

## Media handling

Media is central to this project.

Preserve:

- original MIME type where practical;
- original dimensions;
- X media key or identifier;
- source post ID;
- source URL;
- relevant provenance needed to understand where the media came from.

Do not recompress, resize, convert, or otherwise alter an image merely to pass it between X and an MCP vision client unless a technical requirement makes transformation necessary.

Where transformation is required, preserve the original when permitted and document what changed.

Avoid downloading media repeatedly when a safe and policy-compliant cached copy already exists.

## Data model and serialization

### Language target

Racket is the project's standard implementation target (confirmed by the user
on 2026-10-07). The accepted Python prototype was deprecated and removed after
native runtime feature and contract verification. Python remains only as an
independent MCP client for tests, not as a production dependency.

Keep transport, authentication, media validation, and X API translation separate.
The application is in `racket/`; generic components in `racket/lib/` contain no X
policy. See `docs/racket.md` for boundaries and codec dependencies. Preserve the
synthetic prototype contracts and cross-language MCP tests when changing behavior.
Run `raco test racket/tests.rkt racket/oauth-tests.rkt racket/lib-tests.rkt` and
`raco test racket/chatgpt-file-tests.rkt racket/cancellation-tests.rkt racket/github-tests.rkt racket/github-upload-tests.rkt` and the Python unittest suite.
Native OAuth tests use localhost only, never live X. Read `docs/chatgpt.md` before
changing the tunnel or file-reference path; signed file URLs must stay out of logs
and results, and file downloads must never receive X credentials.

Do not introduce a heavyweight database by reflex.

This project's data needs should emerge from real workflows.

Racket is a welcome choice for durable data manipulation, transformation, serialization, indexing, and analytical work when it keeps those operations clear and inspectable.

The user already uses Racket elsewhere partly because homoiconic data manipulation is useful and partly because it is funny.

Both reasons are valid.

However:

- do not force the MCP transport layer into Racket if another language has materially better MCP or HTTP support;
- do not build elaborate macros merely because Racket permits them;
- do not turn the repository into a programming-language demonstration;
- prefer code a non-specialist can read six months later.

A reasonable future division might be:

```text
MCP / HTTP adapter
        |
X API translation
        |
normalized records
        |
Racket archive / transformations / analysis
```

That is a possibility, not a mandated architecture.

## Racket style

When Racket is used:

- prefer straightforward functions;
- use explicit data shapes;
- use descriptive identifiers;
- keep modules small;
- avoid clever macro systems without a concrete payoff;
- explain surprising choices;
- favor transformations that are easy to inspect in the REPL;
- keep serialized forms reasonably human-readable where practical.

The code should not require the user to become a language-theory nerd in order to maintain their own social-media bridge.

## Implementation style

Prefer boring, explicit engineering.

Good:

- small modules;
- obvious data flow;
- clear boundaries;
- direct API wrappers;
- typed or validated external data where useful;
- meaningful errors;
- minimal dependencies;
- comments explaining why something surprising exists.

Avoid:

- unnecessary frameworks;
- speculative abstraction;
- dependency piles;
- elaborate class hierarchies;
- premature plugin systems;
- generic "enterprise" architecture;
- abstractions built solely to accommodate imaginary future users.

This is initially a personal tool.

Build the tool we actually need.

## External data

Treat X API responses as untrusted external input.

Validate assumptions.

Preserve X IDs as strings unless there is a compelling reason not to.

Do not silently discard API errors.

Expose enough diagnostic information to understand failures without leaking credentials.

When X changes a response schema, normalize that change at the API boundary rather than spreading special cases throughout the application.

## Errors

Errors should answer:

- what operation failed;
- whether the failure came from X, MCP transport, authentication, media retrieval, local processing, or validation;
- whether retrying makes sense;
- what the user or developer can do next.

Preserve useful X error codes and messages where safe.

Do not convert every failure into a generic "something went wrong."

## Testing

Tests should cover the important boundaries:

- X response normalization;
- media retrieval;
- MIME handling;
- malformed URLs;
- unsupported media;
- authentication failures;
- X API failures;
- MCP result construction;
- image-content return behavior;
- upload behavior;
- post-creation request construction.

Live API tests should be clearly separated from ordinary unit tests.

Ordinary test runs must not incur paid writes or publish real content.

Fixtures should contain synthetic or intentionally captured non-secret API examples.

## Verification philosophy

The project exists because an apparently capable interface had surprising omissions.

Therefore, verify behavior empirically.

Do not assume a feature exists because:

- the underlying X API supports it;
- MCP theoretically supports it;
- a documentation page implies it;
- a library has a promising function name.

Exercise the real path and inspect the result.

In particular, for `fetch_x_media`, success means a vision-capable client actually receives and can inspect the image.

For `create_x_post`, success means an explicitly requested live test can create a real post through the intended authentication path.

## Documentation

Keep documentation aligned with observed behavior.

When behavior, configuration, authentication, tool contracts, or important limitations change, update the relevant documentation in the same change.

Document workarounds as workarounds. Do not accidentally fossilize an upstream limitation into a permanent architectural assumption.

## Repository evolution

Codex is encouraged to reorganize this seed into a sensible repository as implementation begins.

It may:

- create a README;
- create architecture or setup documentation;
- choose an implementation language for the MCP adapter;
- add Racket modules where appropriate;
- add tests and fixtures;
- add development scripts;
- split this file into durable instructions plus supporting docs;
- simplify or revise architecture after empirical testing.

Preserve the project's actual goals and constraints while doing so.

The north star is simple:

**Let the robot see the picture, and let it post the picture when explicitly asked.**

## GitHub images

Repository image retrieval and gated image uploads are documented in `docs/github.md`. Keep
GitHub credentials and transport separate from X and ChatGPT file downloads.
Verify original bytes against the returned Git blob SHA; return actual MCP image
content. Private access uses separate Contents: read authorization. Ordinary
tests must not contact GitHub. Do not conflate image reads with issue #1 writes.

GitHub uploads require their own write flag and Contents: write authorization.
Create-only is the default; replacement requires an explicitly supplied current
blob SHA. Never retry an uncertain commit automatically or publish in tests.

## GitHub text

`fetch_github_text` and gated `upload_github_text` are documented in
`docs/github.md`. Preserve exact UTF-8 bytes, explicit expected-SHA replacement,
and immutable-commit verification. Run `raco test racket/github-text-tests.rkt`
alongside existing checks. Durable idempotency claims must never cause an
uncertain submission to be repeated automatically. Keep document contents,
credentials and raw idempotency keys out of logs/journals. Do not infer a policy
prohibition from prose, generic upstream errors, or a
connector-specific safety-check refusal. Evaluate authorized requests under this
tool's own requirements; confirmed applicable policy prohibitions still apply.

`patch_github_text` shares the text-write gate and durable journal. Require the
caller's expected SHA; exact anchors must occur once, including overlapping
matches. Preserve unrelated UTF-8 bytes and never reapply a patch during journal
recovery. Correlate invocations with safe IDs outside replayable receipts; keep
text and raw idempotency keys out of stderr. Missing log entries alone do not
prove a policy prohibition. A refusal in another connector establishes that
channel's outcome, not this tool's outcome or permission to bypass actual enforcement.
