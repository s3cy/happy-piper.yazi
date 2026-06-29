--- @since 06.29.2026
---
--- happy-piper: a lockless re-imagining of faster-piper.
---
--- Design summary (vs. faster-piper):
---   * No lock subsystem. generate_cache writes to a per-call temp file and
---     publishes via rename(2). Concurrent generators are tolerated; the
---     later rename wins. This eliminates the "locked-timeout on resize"
---     class of bugs caused by Yazi cancelling a coroutine mid-generate
---     and orphaning a lock directory.
---   * peek() has a single flow: fresh -> render; not fresh -> regenerate
---     (or, with --rely-on-preloader and no recipe + no cache, render a
---     "warming up..." hint and let the preloader populate).
---   * preload() and peek() share the same code path. Preloaders are an
---     anticipatory perf optimization, not a coordination primitive.
---
local M = {}

local SKIP_JUMP_THRESHOLD = 999
local PEEK_JUMP_THRESHOLD = 99999999

----------------------------------------------------------------------
-- Cache header layout (1-based line numbers)
--
-- A happy-piper cache file is plain text with three header lines, then
-- content. All offset usage MUST go through HEADER.* / content_first_line.
----------------------------------------------------------------------

local HEADER = {
	N = 3,
	LINE_CMD = 1, -- command template (job.args[1]) as-was
	LINE_NLINE = 2, -- number of *content* lines (excludes the 3 hdr lines)
	LINE_W = 3, -- preview width used at generation time
}

local function content_first_line()
	return HEADER.N + 1
end

----------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------

local function is_true(v, default)
	assert(type(default) == "boolean", "is_true: default must be a boolean")
	if v == nil then
		return default
	end
	if v == true then
		return true
	end
	if v == false then
		return false
	end
	if type(v) == "number" then
		return v ~= 0
	end
	if type(v) == "string" then
		v = v:lower()
		if v == "true" or v == "1" or v == "yes" or v == "on" then
			return true
		end
		if v == "false" or v == "0" or v == "no" or v == "off" then
			return false
		end
		return default
	end
	return default
end

-- Convert a Yazi Url to a real filesystem path string for external tools.
-- Search results use virtual URLs (search://...) whose `path` is the real disk path.
local function fs_path(url)
	if url and url.is_search then
		local p = url.path
		if p then
			local s = tostring(p)
			if s ~= "" then
				return s
			end
		end
	end
	return tostring(url)
end

local function split_lines(s)
	local t = {}
	if not s or s == "" then
		return t
	end
	s = s .. "\n"
	for line in s:gmatch("(.-)\n") do
		if not line:match("^%s*$") then
			t[#t + 1] = line .. "\n"
		end
	end
	return t
end

function M.format(job, lines)
	local format = job.args.format
	if format ~= "url" then
		local s = table.concat(lines, ""):gsub("\r", ""):gsub("\t", string.rep(" ", rt.preview.tab_size))
		return ui.Text.parse(s):area(job.area)
	end

	for i = 1, #lines do
		lines[i] = lines[i]:gsub("[\r\n]+$", "")
		local icon = File({
			url = Url(lines[i]),
			cha = Cha({ mode = tonumber(lines[i]:sub(-1) == "/" and "40700" or "100644", 8) }),
		}):icon()
		if icon then
			lines[i] = ui.Line({ ui.Span(" " .. icon.text .. " "):style(icon.style), lines[i] })
		end
	end
	return ui.Text(lines):area(job.area)
end

----------------------------------------------------------------------
-- Cache path / freshness / header read
----------------------------------------------------------------------

local read_cache_header -- forward declaration

local function get_cache_path(job)
	local base = ya.file_cache({ file = job.file, skip = 0 })
	if not base then
		return nil, "caching-disabled-by-yazi"
	end
	return Url(tostring(base)), nil
end

-- Cache is fresh iff it exists, its mtime >= source mtime, its header parses,
-- and the recorded width matches the current preview width.
local function cache_is_fresh(job, cache_path)
	local c = fs.cha(cache_path)
	local s = job.file.cha
	if not (c and c.mtime and s and s.mtime and c.mtime >= s.mtime) then
		return false, nil
	end
	local hdr = read_cache_header(cache_path)
	if not hdr then
		return false, nil
	end
	if hdr.w ~= job.area.w then
		return false, nil
	end
	return true, hdr
end

read_cache_header = function(cache_path)
	local spec = string.format("1,%dp", HEADER.N)

	local out, err = Command("sed")
		:arg({ "-n", spec, tostring(cache_path) })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:stdin(Command.NULL)
		:output()

	if not out then
		return nil, err
	end
	if not out.status.success then
		return nil, out.stderr
	end

	local txt = out.stdout or ""
	if txt == "" then
		return nil, "empty cache header"
	end

	local lines = {}
	local i = 0
	for line in txt:gmatch("([^\n]*)\n") do
		i = i + 1
		lines[i] = line
		if i >= HEADER.N then
			break
		end
	end

	if #lines < HEADER.N then
		return nil, "incomplete cache header (need " .. HEADER.N .. " lines, got " .. #lines .. ")"
	end

	local cmd = lines[HEADER.LINE_CMD]
	local nline = tonumber((lines[HEADER.LINE_NLINE] or ""):match("^%s*(%d+)%s*$"))
	local w = tonumber((lines[HEADER.LINE_W] or ""):match("^%s*(%d+)%s*$"))

	if cmd == nil then
		return nil, "missing cmd header line"
	end
	if not nline then
		return nil, "invalid line-count header: " .. tostring(lines[HEADER.LINE_NLINE])
	end
	if not w then
		return nil, "invalid width header: " .. tostring(lines[HEADER.LINE_W])
	end

	return { cmd = cmd, nline = nline, w = w }, nil
end

----------------------------------------------------------------------
-- Cache generation (lockless, atomic-publish)
--
-- Concurrency model:
--   No lock is taken. Each call writes its output to a per-call temp file
--   (suffixed with the spawned shell's PID, $$) and publishes via rename(2).
--   rename(2) is atomic when source and destination share a filesystem
--   (true here -- both live in Yazi's cache dir), so readers always observe
--   either the previous cache or the new one, never a partial.
--
--   When preload and peek race (e.g. during a terminal-resize burst), both
--   may regenerate. The later rename wins. The worst-case cost is one
--   redundant generator invocation -- dramatically cheaper than the
--   multi-second stalls the previous lock-based design could exhibit when
--   a coroutine was cancelled mid-flight and orphaned the lock directory.
--
-- Recipe resolution (behavior unchanged from faster-piper):
--   1) If job.args[1] is provided, use it as the template.
--   2) Else, if a cache exists with a valid header, reuse hdr.cmd
--      (so peek() can self-heal even when its rule has no `-- cmd` payload).
--   3) Else, fail.
----------------------------------------------------------------------
local function generate_cache(job, cache_path)
	local source_path = fs_path(job.file.url)

	local tpl = job.args and job.args[1]
	if tpl == "" then
		tpl = nil
	end

	if not tpl then
		local cha = fs.cha(cache_path)
		if cha then
			local hdr, herr = read_cache_header(cache_path)
			if hdr and hdr.cmd and hdr.cmd ~= "" then
				tpl = hdr.cmd
			else
				ya.err("happy-piper: cache header invalid; cannot reuse recipe: " .. tostring(herr))
			end
		end
	end

	if not tpl or tpl == "" then
		ya.err("happy-piper: missing generator command template (job.args[1]) and no usable cached header")
		return false
	end

	-- Guard: single-line templates only (env transport + header layout assume this).
	if tpl:find("\n", 1, true) then
		ya.err("happy-piper: command template contains newline; unsupported")
		return false
	end

	-- Expand "$1" against the source path safely; the rest of the template
	-- is shell-interpreted as before ($w, $h, env vars, pipes still work).
	local final = tpl:gsub('"$1"', ya.quote(source_path))

	-- Script notes:
	--   * `set -e`           : fail fast on any step error.
	--   * `$$`               : the spawned shell's PID, used to make TMP_RAW /
	--                          TMP_FINAL unique among concurrent generators.
	--   * `trap cleanup EXIT`: leaves no temp files on disk regardless of
	--                          success / failure / signal exit.
	--   * `mv TMP_FINAL FP_CACHE`: atomic publication. Readers see either the
	--                          previous cache or the new one, never partial.
	local script = string.format(
		[[
set -e
TMP_RAW="$FP_CACHE.$$.raw"
TMP_FINAL="$FP_CACHE.$$.final"
cleanup() { rm -f "$TMP_RAW" "$TMP_FINAL"; }
trap cleanup EXIT
(%s) > "$TMP_RAW"
L=$(wc -l < "$TMP_RAW" | tr -d '[:space:]')
W=$(printf '%%s' "$w" | tr -d '[:space:]')
{
  printf '%%s\n' "$FP_TPL"
  printf '%%s\n' "$L"
  printf '%%s\n' "$W"
  cat "$TMP_RAW"
} > "$TMP_FINAL"
mv "$TMP_FINAL" "$FP_CACHE"
]],
		final
	)

	local child, err = Command("sh")
		:arg({ "-c", script })
		:env("w", tostring(job.area.w))
		:env("h", tostring(job.area.h))
		:env("FP_TPL", tpl) -- exact template stored in header line 1
		:env("FP_CACHE", tostring(cache_path))
		:stdin(Command.NULL)
		:stdout(Command.NULL)
		:stderr(Command.PIPED)
		:spawn()

	if not child then
		ya.err("happy-piper: failed to spawn: " .. tostring(err))
		return false
	end

	local output, werr = child:wait_with_output()
	if not output then
		ya.err("happy-piper: wait failed: " .. tostring(werr))
		return false
	end

	if not output.status.success then
		ya.err(
			"happy-piper: command failed (code=" .. tostring(output.status.code) .. "): " .. tostring(output.stderr)
		)
		return false
	end

	-- Final sanity check: the cache we just published parses.
	local hdr, herr = read_cache_header(cache_path)
	if not hdr then
		ya.err("happy-piper: published cache but header sanity-check failed: " .. tostring(herr))
		return false
	end
	return true
end

-- Ensure a fresh cache exists. No-op if already fresh.
local function ensure_cache(job)
	local cache_path, why = get_cache_path(job)
	if not cache_path then
		return nil, why
	end
	if cache_is_fresh(job, cache_path) then
		return cache_path
	end
	if not generate_cache(job, cache_path) then
		return nil, "generate-failed"
	end
	return cache_path
end

----------------------------------------------------------------------
-- Yazi hooks
----------------------------------------------------------------------

function M:preload(job)
	return ensure_cache(job) ~= nil
end

----------------------------------------------------------------------
-- seek() -- sentinel-based "jump to end" protocol.
--
-- Yazi's scrolling model passes an integer `skip` into peek(). seek() is
-- stateless and arg-agnostic: it does NOT know total line count, whether
-- a cache exists, or which command produced it. It also cannot share Lua
-- state with peek() (Yazi may reload state between calls).
--
-- To implement "jump to end" without knowing the file length here, seek()
-- emits a sentinel skip value (cur + PEEK_JUMP_THRESHOLD + 1). peek() reads
-- the line count from the cache header, detects the sentinel, and re-emits
-- peek() with the correct clamped skip. peek() MUST NOT silently clamp on
-- its own -- Yazi tracks preview state via the requested skip and would
-- desynchronize.
----------------------------------------------------------------------
function M:seek(job)
	local cur = cx.active.preview.skip or 0
	local units = job.units or 0
	local new_skip = cur + units

	if units < -SKIP_JUMP_THRESHOLD then
		new_skip = 0
	end

	if units > SKIP_JUMP_THRESHOLD then
		ya.emit("peek", { cur + PEEK_JUMP_THRESHOLD + 1, only_if = job.file.url })
		return
	end

	new_skip = math.max(0, new_skip)
	ya.emit("peek", { new_skip, only_if = job.file.url })
end

----------------------------------------------------------------------
-- peek() -- single flow, no locks
--
-- 1. Compute cache path.
-- 2. If cache is fresh, render it.
-- 3. Otherwise:
--    a) With --rely-on-preloader AND no recipe (no args[1], no usable cache
--       header) AND no cache file at all: render "warming up" and return.
--       The preloader will populate; Yazi will re-peek.
--    b) Otherwise: regenerate synchronously via the lockless generator.
-- 4. Clamp skip if necessary, then render the slice via sed.
----------------------------------------------------------------------
function M:peek(job)
	local cache_path, why = get_cache_path(job)
	if not cache_path then
		ya.preview_widget(job, ui.Text.parse("happy-piper: " .. tostring(why)):area(job.area))
		return
	end

	local ok, hdr = cache_is_fresh(job, cache_path)
	if not ok then
		local relies = is_true(job.args.rely_on_preloader, false)
		local has_args_recipe = job.args and job.args[1] and job.args[1] ~= ""
		local cache_exists = fs.cha(cache_path) ~= nil

		if relies and not has_args_recipe and not cache_exists then
			ya.preview_widget(job, ui.Text.parse("happy-piper: warming up…"):area(job.area))
			return
		end

		local gen_ok = generate_cache(job, cache_path)
		if not gen_ok then
			ya.preview_widget(
				job,
				ui.Text.parse("happy-piper: failed to (re)generate cache"):area(job.area)
			)
			return
		end

		hdr = read_cache_header(cache_path)
	end

	-- Clamp skip if necessary, using the (now-fresh) header total.
	if hdr then
		local total = hdr.nline
		local limit = job.area.h
		local max_skip = math.max(0, total - limit)
		local skip = job.skip or 0

		if total <= PEEK_JUMP_THRESHOLD and skip > PEEK_JUMP_THRESHOLD and skip ~= max_skip then
			ya.emit("peek", { max_skip, only_if = job.file.url })
			return
		end

		if skip > max_skip then
			ya.emit("peek", { max_skip, only_if = job.file.url })
			return
		end
	else
		ya.err("happy-piper: failed to read cache header after generation")
	end

	local limit = job.area.h
	local skip = job.skip or 0
	local start = skip + content_first_line()
	local stop = start + limit - 1

	local qpath = tostring(cache_path)
	local range = string.format("%d,%dp", start, stop)

	local out, err = Command("sed")
		:arg({ "-n", range, qpath })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:stdin(Command.NULL)
		:output()

	if not out then
		ya.preview_widget(job, ui.Text.parse("happy-piper: sed(slice): " .. tostring(err)):area(job.area))
		return
	end
	if not out.status.success then
		ya.preview_widget(job, ui.Text.parse("happy-piper: sed(slice): " .. out.stderr):area(job.area))
		return
	end

	if job.args.format == "url" then
		local lines = split_lines(out.stdout)
		ya.preview_widget(job, M.format(job, lines))
	else
		ya.preview_widget(job, ui.Text.parse(out.stdout):area(job.area))
	end
end

function M:entry(job)
	return
end

return M
