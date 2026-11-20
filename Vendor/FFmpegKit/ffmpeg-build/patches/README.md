# FFmpeg patches (FFmpegKit's set, for FFmpeg n9.1)

These are the 13 patches kingslay/FFmpegKit applies to FFmpeg, taken from
`Plugins/BuildFFmpeg/patch/FFmpeg/` at its tag `9.0.2` (commit `20e3ba2`). The numbering,
including the missing `06`, is upstream's. `apply_patches.sh` applies them in name order with
`git apply` and stops the build if any of them does not apply.

Ten files are byte-for-byte copies; they apply to n9.1 with line offsets only:

`01-videotoolbox`, `02-hls`, `03-ac4`, `04-mlpdec-truehd`, `07-mkv-cues_parsing_deferred`,
`08-wavdec-list-tag`, `09-dec_init`, `11-exported_symbols`, `12-hlsenc-remove-dash`,
`13-tls-verify`.

Three did not apply to n9.1 because the surrounding FFmpeg code changed, and were re-made
against n9.1 by hand (owner sign-off 2026-11-20). The change each one makes is the same as
upstream's; only what is listed below differs. None of them was upstreamed into FFmpeg.

## 05-h264_seek.patch
- Upstream: in `h264_init_ps()` replace `get_pixel_format(h, must_reinit || needs_reinit)`
  with `get_pixel_format(h, 1)`.
- n9.1: `get_pixel_format()` has a third parameter (H.264 data partitioning), so the call is
  `get_pixel_format(h, must_reinit || needs_reinit, sl->data_partitioning)` over two lines.
- Here: the call becomes `get_pixel_format(h, 1, sl->data_partitioning)`. The second
  argument is forced to 1 exactly as upstream does; the new third argument is passed through
  unchanged.

## 10-http-redirect-cache.patch
- Upstream: three hunks in `libavformat/http.c` — a new `int redirects_expires` field in
  `HTTPContext`, a new `redirects_expires` AVOption (default -1), and
  `(time(NULL) + s->redirects_expires)` instead of `-1` for the expiry of a non-permanent
  redirect.
- n9.1: `HTTPContext` was reorganized into sections, so the field no longer sits at the end
  of the struct, and the context lines around the other two hunks moved.
- Here: the field is added directly after `int max_redirects;` (the same neighbour as
  upstream, now inside the options section); the option line and the expiry expression are
  character-for-character upstream's.

## 14-dashdec-seek.patch
- Upstream: four replacements in `libavformat/dashdec.c` (`av_rescale` instead of overflowing
  integer arithmetic in `dash_seek()`, and seeking allowed on live streams).
- n9.1: a line was added after the third replacement
  (`pls->cur_seq_no = FFMAX(pls->cur_seq_no, pls->first_seq_no);`), which broke that hunk's
  context.
- Here: the same four replacements; n9.1's new `FFMAX` line is kept as it is.

## Bumping FFmpeg
Take FFmpegKit's patch folder at the matching tag if one exists. Otherwise run
`apply_patches.sh` against the new FFmpeg tree; for a patch that fails, check whether FFmpeg
has taken the change itself (then delete the file) or the context moved (then re-make it and
record it here). `13-tls-verify` turns TLS certificate verification off by default; that is
upstream's choice and is kept only because verification needs a CA bundle the app does not
ship yet.
