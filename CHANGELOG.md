# Changelog

All notable changes to this project will be documented here.

## [0.4.0](https://github.com/genagent/oban_codex/compare/v0.3.2...v0.4.0) (2026-09-24)


### Features

* preserve application correlation through agent turns (closes [#22](https://github.com/genagent/oban_codex/issues/22)) ([#23](https://github.com/genagent/oban_codex/issues/23)) ([787380c](https://github.com/genagent/oban_codex/commit/787380c54ad30dc594ae545a4d07cd149ba6327f))

## [0.3.2](https://github.com/genagent/oban_codex/compare/v0.3.1...v0.3.2) (2026-09-24)


### Bug Fixes

* forward skip_git_repo_check through run/2 ([#20](https://github.com/genagent/oban_codex/issues/20)) ([9d9e767](https://github.com/genagent/oban_codex/commit/9d9e767d679981eb23597e36cf8f5f05b8de9d6b))

## [0.3.1](https://github.com/genagent/oban_codex/compare/v0.3.0...v0.3.1) (2026-09-24)


### Bug Fixes

* contain enqueue failures without terminating the agent ([#17](https://github.com/genagent/oban_codex/issues/17)) ([3598155](https://github.com/genagent/oban_codex/commit/35981551145c91900e72cc9d863390ed62981706))

## [0.3.0](https://github.com/genagent/oban_codex/compare/v0.2.0...v0.3.0) (2026-09-23)


### Features

* add named session arcs ([#13](https://github.com/genagent/oban_codex/issues/13)) ([1098655](https://github.com/genagent/oban_codex/commit/1098655c48948dc676fcfee85b48dfdb09014333))

## [0.2.0](https://github.com/genagent/oban_codex/compare/v0.1.0...v0.2.0) (2026-09-23)


### Features

* allow one-turn args on agent approval (closes [#9](https://github.com/genagent/oban_codex/issues/9)) ([#10](https://github.com/genagent/oban_codex/issues/10)) ([c843892](https://github.com/genagent/oban_codex/commit/c843892f36efe0d5fb2fe2f6a562935dc0b4a8bd))


### Bug Fixes

* correlate agent callbacks with their owning turn and generation (closes [#4](https://github.com/genagent/oban_codex/issues/4)) ([#5](https://github.com/genagent/oban_codex/issues/5)) ([6a25406](https://github.com/genagent/oban_codex/commit/6a2540645891121d197bfd36f483c4de1052ccc4))
* refresh vulnerable Mint and Igniter locks (closes [#6](https://github.com/genagent/oban_codex/issues/6)) ([#7](https://github.com/genagent/oban_codex/issues/7)) ([344837f](https://github.com/genagent/oban_codex/commit/344837fee4c12c16fb2ec02b0276b001b972844c))

## [0.1.0](https://github.com/genagent/oban_codex/releases/tag/v0.1.0) (2026-07-29)


### Features

* scaffold oban_codex ([2298e8b](https://github.com/genagent/oban_codex/commit/2298e8be0670856439d1ce654addc53deae2434c))


### Miscellaneous Chores

* release initial version as 0.1.0 ([#2](https://github.com/genagent/oban_codex/issues/2)) ([1598e98](https://github.com/genagent/oban_codex/commit/1598e98958207756921aab6983c1b1396d0edcc8))
