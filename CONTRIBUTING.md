# Contributing to iOdus

Thank you for your help. This guide tells you how to report a problem, how to
suggest a change, and how to send a pull request.

iOdus is a project that one person maintains in free time. A reply can take
some days.

## Before you start

- Read the [README](README.md), and the section [Known limits](README.md#known-limits).
- Search the [open and closed issues](https://github.com/burghr/iOdus/issues?q=is%3Aissue).
  Another person possibly reported the same problem.
- iOdus is an unofficial project. Do not report iOdus problems to Microsoft,
  Xbox, Apple, or CodeWeavers.

## Report a bug

Use the **Bug report** form on the
[new issue page](https://github.com/burghr/iOdus/issues/new/choose).

Attach the log export to the report:

1. Open **Settings**.
2. Select **Export logs**. iOdus writes a zip file to the Desktop.
3. Attach the zip file to the issue.

The log export does not contain tokens, email addresses, XUIDs, your account
name, your user name, or your home folder. Do not attach other files that
contain this data.

## Get games legally

iOdus installs only the games that your Microsoft account owns or that Game
Pass for PC gives you. We do not help with games from other sources. We close
issues about pirated games, cracked games, or copies of games from other
people.

## Suggest a feature

Open an issue that tells:

- what you want to do,
- why the current iOdus does not let you do it,
- how you think that the feature can work.

## Send a pull request

Before you start work on a large change, open an issue. Then we can agree on
the plan before you write the code.

### Set up

Follow the steps in [Build from source](README.md#build-from-source). You need:

- a Mac with Apple silicon and macOS 15 or later,
- Xcode with the Swift 6 tools,
- the backend [iodus-xodus](https://github.com/burghr/iodus-xodus/tree/iodus)
  (branch `iodus`), for changes that need a real account.

For changes to the user interface, you do not need an account:

```sh
swift build
.build/debug/iOdus --demo --windowed         # sample games, no account
.build/debug/iOdus --snapshot out.png home   # one frame of a screen to a PNG file
```

### Test

Before you send the pull request, run all the unit tests:

```sh
swift test
```

The unit tests use no network and no Wine. They do not use the real folders
in `~/Library/Application Support/iOdus`. Keep the new tests the same.

- Add tests for new logic and for bug fixes.
- For a change to a screen, attach a screenshot (from `--snapshot`) to the
  pull request.
- Tests that read real data run only with `IODUS_LIVE=1`. Do not make them
  run by default.

### Xbox Live: real data only

This rule is the most important rule of the project.

Code and tests must never send fabricated or test data to Xbox Live or to
other Microsoft services. This includes:

- events, achievement unlocks, and statistics,
- presence,
- saves,
- messages, friend actions, and Store actions.

Read requests are allowed. Data from real use is allowed, for example a normal
game start or a save that a game writes.

For a test of code that writes to a service, use a fake server or injected
responses. Do not use the real service. We do not merge a pull request that
breaks this rule.

### Wine prefixes

Do not run Wine tests in your real iOdus prefix. Use a separate prefix for
manual tests. Do not rebuild the app bundle while a game runs.

### Code style

- Use the style of the code near your change.
- Keep a pull request to one subject. Send two pull requests for two subjects.
- Write a comment when the reason for the code is not clear from the code.
- Do not add new dependencies without a discussion in an issue first.

### Commit messages

- Write the first line in the imperative, for example "Add a filter for
  installed games".
- Keep the first line to about 60 characters.
- In the body, tell why you made the change.
- Do not put "fixes #N" or "closes #N" in the message. Use "for #N".
  The maintainer closes an issue after the reporter confirms the fix.

### AI tools and other tools

You can use AI tools and other tools to help you write code. You are the
author of the contribution, and you are responsible for it. Make sure that
you understand each change, and test it yourself.

Do not credit a tool as a contributor:

- Do not add `Co-Authored-By` lines for a tool or an AI assistant.
- Do not add "Generated with" lines or links to a tool session.
- Do not add files for the configuration or the instructions of a tool to the
  pull request. Examples: `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.cursor/`,
  and `.github/copilot-instructions.md`.

Before you push, remove these lines from the commit messages and from the
description of the pull request. To tell us that you used AI tools, use the
checkbox in the template for the pull request.

### The pull request

When you open a pull request, GitHub fills the description with a template.
Complete each part of the template:

- what the change does, and why the change is necessary,
- the issue that it is for, if there is one,
- how you tested it (macOS version, Mac model, runtime, and the games),
- the checks,
- whether you used AI tools. AI tools are allowed. We ask only so that we can
  review the change correctly.

## License

iOdus uses the [GNU General Public License version 3](LICENSE). When you send a
pull request, you agree that your contribution uses the same license.
