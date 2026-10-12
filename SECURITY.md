# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub. Open the **Security** tab of this repository and choose **Report a vulnerability**, or go to <https://github.com/mimo-3/polaris/security/advisories/new>. Please do not open a public issue or pull request for a vulnerability. Reports in Japanese are also welcome. 日本語での報告も受け付けています。

A useful report includes the affected commit, steps to reproduce, and what an attacker can do.

This is a personal project, so responses are best effort. I aim to reply within two weeks.

## Supported versions

There are no releases yet. Only the latest commit on the `main` branch receives security fixes.

## Threat model

Polaris keeps its state in `~/.polaris/state.json`, or in the directory set by `POLARIS_HOME`. After symlinks are resolved, the directory must be owned by the user and not writable by group or others. Polaris then sets its permissions to 700. Any process running as the same user can already change it, so such processes are inside the trust boundary. Reports that need the same user's access to edit the state file are out of scope.

An MCP client connected to `polaris-mcp` can write any content within the tools' input limits, including a banner shown on the note. Polaris shows the sender of such a banner as `MCP: <client name>`. Content that a client writes through the tools as intended is not a vulnerability. Input from a client that crashes Polaris, writes outside the state directory, or causes similar harm is in scope.

`polaris-mcp` talks only over stdio. Neither the app nor `polaris-mcp` opens a network connection.
