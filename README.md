# envsh

Open a shell with a `.env` file loaded. Type `exit` when you're done.

![demo](demo.gif)

```
$ envsh .env.test
envsh: loaded .env.test
$ mysqlsh --uri "$DATABASE_URL"
$ exit
```

## Usage

```
envsh [PATH]                 open $SHELL with PATH loaded
envsh [PATH] -- CMD [ARGS]   run CMD with PATH loaded instead
```

PATH defaults to `./.env`, so plain `envsh` loads the usual file. If a file name
starts with `-`, write it as `./-name`.

Variables from the file win over anything already in your environment. envsh also
sets `ENVSH` to the file's name (`.env.test` for `config/.env.test`), and it won't
run if `ENVSH` is already set, so you can't accidentally end up with prod loaded on
top of test.

To show it in your prompt, with bash:

```bash
PS1='${ENVSH:+[$ENVSH] }'"$PS1"
```

or with starship:

```toml
[env_var.ENVSH]
format = "[\\[$env_value\\]]($style) "
style = "bold red"
```

## The .env format

Every tool reads `.env` files a little differently, so envsh only accepts the
simple part they all agree on. If a file loads here, it means the same thing
everywhere. Anything else is an error.

```sh
# comments start at the beginning of the line
DATABASE_URL=mysql://user:pa%40ss@db.example.com:3306/app
GREETING='single quotes for spaces and other special characters'
EMPTY=
```

- `KEY=value`, with no spaces around the `=` and no `export` in front.
- Unquoted values can only contain letters, numbers, and `_ - . / : @ % + , =`.
- For anything else, use single quotes. What's inside is taken literally.
- No double quotes, no escapes, no `${VAR}`, no multi-line values, and nothing
  after the value (not even a comment).
- Each key can only appear once.

Errors tell you the line and column, but they never print the value, so secrets
won't leak into your terminal.

## Building

```
zig build          # binary ends up in zig-out/bin/envsh
zig build test
```

The parser is also available as a Zig module called `dotenv`, if you want to use
it in your own project.

macOS and Linux only.
