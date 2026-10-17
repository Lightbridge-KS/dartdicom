# dartdicom_examples

Runnable end-to-end examples across the dartdicom packages. This is a workspace member that is never published. It is the only place where several packages are used together.

| Example | What it shows |
|---|---|
| `bin/retrieve_and_render.dart` | The first consumer's path: C-ECHO, C-FIND (study, then series), C-GET of one series into a `DirectorySink`, then the first frame of a stored file rendered as an 8-bit PGM |

Run it against the test PACS from the repo root:

```sh
just pacs-up && just pacs-seed
cd examples && dart run bin/retrieve_and_render.dart --patient-id=1CT1
```

Flags: `--host`, `--port`, `--called-ae`, `--calling-ae`, `--patient-id`, `--out`. Defaults match `docker/compose.yaml`. `just live` runs it as part of the live gates and checks the image.
