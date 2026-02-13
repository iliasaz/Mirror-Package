# Mirror-Package

A command-line tool to create or update a local mirror of the dependencies for a
Swift project. This tool is meant to automate a bunch of the typing that is
involved in using SPM [dependency mirroring].

## Basic Usage

Let's say that you want to keep a local mirror of your project's dependencies
in a directory, `/opt/swift/mirrors`. Open a terminal window and change to
your swift project's directory. Then resolve your project's package dependencies:

`swift package resolve`

Now you can use the tool to mirror all the dependencies:

`Mirror-Package -m /opt/swift/mirrors`

Later, if you want to update your local mirrors, you can use the tool to do
that, too:

`Mirror-Package -m /opt/swift/mirrors -u`

Note that the update process can happen from any directory, since it just
goes through all the subdirectories of the specified mirror directory and
does a `git pull --rebase` for each one.

To stop using the mirrors, simply delete `.swiftpm/configure/mirrors.json` from your project.

## Options and Flags

| Option / Flag | Short | Description | Default |
|---|---|---|---|
| `--mirror-path` | `-m` | Directory which will hold the local mirrors | *(required)* |
| `--git-path` | `-g` | Path to the git executable | `/usr/bin/git` |
| `--swift-path` | `-s` | Path to the swift executable | `/usr/bin/swift` |
| `--with-sha / --no-with-sha` | `-w` | Use exact revisions for shallow clones | `true` |
| `--update / --no-update` | `-u` | Update all local mirrors in the mirror directory | `false` |
| `--docker-mirror-path` | `-d` | Directory for local mirrors inside a Docker container | `/app/external-deps/checkouts` |

### Shallow Clones with `--with-sha`

By default, Mirror-Package performs space-efficient shallow clones by fetching only the exact revision recorded in `Package.resolved`. This uses `git fetch --depth 1` with the pinned commit SHA, resulting in significantly smaller mirror directories.

To fall back to full `git clone`, pass `--no-with-sha`:

`Mirror-Package -m /opt/swift/mirrors --no-with-sha`

### Docker Mirror Configuration with `--docker-mirror-path`

When mirroring dependencies, the tool also generates a `docker-mirrors.json` file in your project directory. This file follows SPM's `mirrors.json` format and maps original package URLs to paths inside a Docker container.

The default Docker mirror path is `/app/external-deps/checkouts`. You can customize it:

`Mirror-Package -m /opt/swift/mirrors -d /workspace/mirrors`

To use the generated config in a Docker build, copy both the mirror directory and the config file into your image:

```dockerfile
COPY external-deps /app/external-deps
COPY docker-mirrors.json /app/.swiftpm/configuration/mirrors.json
```

[dependency mirroring]: https://github.com/apple/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md
