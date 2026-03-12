--[[

YouTube Storyboard Thumbnailer
Implements the OSC thumbnailer API for YouTube storyboards via yt-dlp/youtube-dl.

When playing a YouTube video, this script automatically downloads the storyboard
(yt-dlp format "sb0" 180p preferred, "sb1" 90p fallback) and displays thumbnails
when hovering over the OSC seekbar.

Requirements:
  - yt-dlp or youtube-dl (loaded via ytdl_hook.lua)
  - ffmpeg (for converting thumbnails to the bgra format expected by overlay-add)

Usage:
  Place this script in your mpv scripts directory (~/.config/mpv/scripts/).
  It will activate automatically when playing a YouTube video.

--]]

local msg   = require 'mp.msg'
local utils = require 'mp.utils'

-- Overlay ID used for displaying thumbnails. Change this if it conflicts with
-- another script.
local OVERLAY_ID = 16

-- Per-session temp directory (created lazily on first YouTube video).
local tmpdir = nil

-- Current storyboard state. nil when no storyboard is available.
local sb = nil

-- Whether a thumbnail extraction (ffmpeg) is currently in progress.
local extracting = false

-- Set to false when the OSC sends a nil (clear) request; prevents an
-- in-flight ffmpeg callback from re-adding the overlay after it was removed.
local overlay_enabled = false

-- The latest unprocessed thumbnail request. Only the most recent one is kept.
local pending_req = nil

-- Signal to the OSC that we handle thumbnail requests.
mp.set_property_native("user-data/thumbnailer/enabled", true)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Return (and create on first call) the per-session temp directory.
-- The directory name includes mpv's PID so parallel mpv instances do not
-- interfere with each other.
local function get_tmpdir()
    if tmpdir then return tmpdir end
    local base
    if mp.get_property_native("platform") == "windows" then
        base = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("LOCALAPPDATA")
    else
        base = os.getenv("TMPDIR") or os.getenv("TMP") or os.getenv("TEMP") or "/tmp"
    end
    if not base then base = "/tmp" end
    tmpdir = utils.join_path(base, "mpv-yt-thumb-" .. tostring(utils.getpid()))
    if mp.get_property_native("platform") == "windows" then
        mp.command_native({
            name          = "subprocess",
            args          = {"cmd", "/c", "mkdir", tmpdir},
            playback_only = false,
        })
    else
        mp.command_native({
            name          = "subprocess",
            args          = {"mkdir", "-p", tmpdir},
            playback_only = false,
        })
    end
    return tmpdir
end

-- ---------------------------------------------------------------------------
-- MHTML parsing
-- ---------------------------------------------------------------------------

-- Parse an MHTML file produced by yt-dlp and save each embedded sprite image
-- as a separate file.  Files are named sprite_<n>.<ext>.
-- Returns the number of sprite images saved.
--
-- yt-dlp produces a non-standard MHTML:
--   * No "Content-Type: multipart/related; boundary=..." outer header.
--     The boundary is the first "--<boundary>" line in the preamble.
--   * Each part body is raw binary with a "Content-length" header.
--     We must use that length to read the image and never search for the
--     boundary inside binary data.
local function parse_mhtml(mhtml_path)
    local f = io.open(mhtml_path, "rb")
    if not f then
        msg.error("Cannot open mhtml: " .. mhtml_path)
        return 0
    end
    local data = f:read("*a")
    f:close()

    -- Locate the boundary.
    -- First try the standard MIME multipart Content-Type header.
    local boundary = data:match('Content%-Type:%s*multipart/related[^\r\n]*boundary="([^"]+)"')
    if not boundary then
        boundary = data:match("Content%-Type:%s*multipart/related[^\r\n]*boundary=([%w%+%-%._=]+)")
    end
    -- yt-dlp omits that header entirely; scan the preamble for the first
    -- "--<boundary>" line (preamble is plain text, so this is safe).
    if not boundary then
        for line in data:sub(1, 512):gmatch("[^\r\n]+") do
            if line:sub(1, 2) == "--" and #line > 2 then
                boundary = line:sub(3):match("^(.-)%s*$")  -- strip trailing whitespace
                break
            end
        end
    end
    if not boundary then
        msg.error("Cannot find MIME boundary in storyboard mhtml")
        return 0
    end

    local sep   = "--" .. boundary
    local count = 0
    local pos   = 1
    local dir   = get_tmpdir()

    while true do
        local s = data:find(sep, pos, true)
        if not s then break end

        local after = s + #sep

        -- "--boundary--" signals the end of the multipart body.
        if data:sub(after, after + 1) == "--" then break end

        -- Skip the CRLF (or plain LF) after the boundary line.
        if data:sub(after, after) == "\r" then after = after + 1 end
        if data:sub(after, after) == "\n" then after = after + 1 end

        -- Parse headers line by line until the blank line.
        local ct, cl
        local hpos = after
        while true do
            local line_end = data:find("\n", hpos, true)
            if not line_end then break end
            local line = data:sub(hpos, line_end - 1):gsub("\r$", "")
            if line == "" then
                hpos = line_end + 1
                break
            end
            local hname, hval = line:match("^([^:]+):%s*(.*)")
            if hname then
                local lname = hname:lower()
                if lname == "content-type" then
                    ct = hval:match("^%s*(.-)%s*$")
                elseif lname == "content-length" then
                    cl = tonumber(hval)
                end
            end
            hpos = line_end + 1
        end

        if ct and ct:lower():match("^image/") and cl and cl > 0 then
            count = count + 1
            local ext = ct:lower():match("^image/(%w+)") or "webp"
            if ext == "jpeg" then ext = "jpg" end

            local sprite_path = utils.join_path(
                dir, "sprite_" .. count .. "." .. ext)

            -- Read exactly cl bytes of raw binary image data.
            local img_data = data:sub(hpos, hpos + cl - 1)

            local out = io.open(sprite_path, "wb")
            if out then
                out:write(img_data)
                out:close()
            else
                msg.warn("Could not write sprite: " .. sprite_path)
            end

            -- Jump directly past the image data so the next boundary search
            -- never scans inside binary content.
            pos = hpos + cl
        else
            pos = after
        end
    end

    return count
end

-- ---------------------------------------------------------------------------
-- Storyboard state management
-- ---------------------------------------------------------------------------

-- Build the storyboard state table from the yt-dlp JSON and the number of
-- sprite images that were successfully extracted.
local function setup_storyboard(json, fmt_id, num_sprites)
    if num_sprites == 0 then return end

    -- Locate the chosen format entry.
    local sb_fmt = nil
    for _, fmt in ipairs(json.formats or {}) do
        if fmt.format_id == fmt_id then
            sb_fmt = fmt
            break
        end
    end
    if not sb_fmt then
        msg.warn(fmt_id .. " format entry not found in JSON")
        return
    end

    -- Build a cumulative start-time array for all fragments.
    -- frag_start_times[i] is the playback position (seconds) at which
    -- sprite i begins.
    local frag_start_times = {}
    local t = 0
    for i, frag in ipairs(sb_fmt.fragments or {}) do
        frag_start_times[i] = t
        t = t + (frag.duration or 0)
    end

    local rows = sb_fmt.rows
    local cols = sb_fmt.columns
    local tw   = sb_fmt.width
    local th   = sb_fmt.height
    if not (rows and cols and tw and th) then
        msg.warn("Storyboard format missing dimension info")
        return
    end

    sb = {
        rows             = rows,
        cols             = cols,
        thumb_w          = tw,
        thumb_h          = th,
        total_per_sprite = rows * cols,
        frag_start_times = frag_start_times,
        num_sprites      = num_sprites,
    }

    msg.verbose(string.format(
        "Storyboard ready: %d sprite(s), %dx%d grid, %dx%d px/thumb",
        num_sprites, cols, rows, tw, th))
end

-- ---------------------------------------------------------------------------
-- Thumbnail lookup and display
-- ---------------------------------------------------------------------------

-- Return (sprite_path, src_x, src_y) for the thumbnail closest to hover_sec,
-- or nil if not available.
local function find_thumbnail(hover_sec)
    if not sb or sb.num_sprites == 0 then return nil end

    local fst = sb.frag_start_times
    if not fst or #fst == 0 then return nil end

    -- Binary-search-style: walk from the end to find the last fragment whose
    -- start time is ≤ hover_sec.
    local sprite_idx = 1
    for i = #fst, 1, -1 do
        if hover_sec >= fst[i] then
            sprite_idx = i
            break
        end
    end
    if sprite_idx < 1 or sprite_idx > sb.num_sprites then return nil end

    -- Duration of the chosen sprite.
    local sprite_dur
    if sprite_idx < #fst then
        sprite_dur = fst[sprite_idx + 1] - fst[sprite_idx]
    else
        local total = mp.get_property_number("duration") or 0
        sprite_dur  = total - fst[sprite_idx]
    end
    if sprite_dur <= 0 then sprite_dur = 1 end

    -- Index of the thumbnail within the sprite grid.
    local local_time = hover_sec - fst[sprite_idx]
    local thumb_idx  = math.floor(local_time / sprite_dur * sb.total_per_sprite)
    thumb_idx = math.max(0, math.min(sb.total_per_sprite - 1, thumb_idx))

    local row   = math.floor(thumb_idx / sb.cols)
    local col   = thumb_idx % sb.cols
    local src_x = col * sb.thumb_w
    local src_y = row * sb.thumb_h

    -- The extension was determined at parse time; try common ones.
    local dir = get_tmpdir()
    for _, ext in ipairs({"jpg", "jpeg", "webp", "png"}) do
        local p  = utils.join_path(dir,
            "sprite_" .. sprite_idx .. "." .. ext)
        local fh = io.open(p, "rb")
        if fh then
            fh:close()
            return p, src_x, src_y
        end
    end

    return nil
end

-- Extract and display the thumbnail for req using ffmpeg (async).
-- Only one extraction runs at a time; any request that arrives while one is
-- in flight is saved in pending_req and processed in the callback.
local function do_show_thumbnail(req)
    if not sb then
        extracting = false
        return
    end

    local sprite_path, sx, sy = find_thumbnail(req.hover_sec)
    if not sprite_path then
        extracting = false
        return
    end

    local out_w     = req.w
    local out_h     = req.h
    local bgra_path = utils.join_path(get_tmpdir(), "thumb.bgra")

    mp.command_native_async({
        name          = "subprocess",
        args          = {
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", sprite_path,
            "-vf", string.format("crop=%d:%d:%d:%d,scale=%d:%d",
                sb.thumb_w, sb.thumb_h, sx, sy, out_w, out_h),
            "-f", "rawvideo", "-pix_fmt", "bgra",
            bgra_path,
        },
        capture_stderr = false,
        playback_only  = false,
    }, function(success, result)
        extracting = false
        -- Discard if the OSC has cleared the thumbnail request in the meantime.
        if not overlay_enabled then return end

        if success and result.status == 0 then
            mp.command_native({
                name   = "overlay-add",
                id     = OVERLAY_ID,
                x      = req.x,
                y      = req.y,
                file   = bgra_path,
                offset = 0,
                fmt    = "bgra",
                w      = out_w,
                h      = out_h,
                stride = out_w * 4,
                dw     = req.w,
                dh     = req.h,
            })
        else
            msg.debug("ffmpeg thumbnail extraction failed")
        end

        -- If a newer request arrived while we were busy, handle it now.
        if pending_req then
            local next_req = pending_req
            pending_req    = nil
            extracting     = true
            do_show_thumbnail(next_req)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Property observers
-- ---------------------------------------------------------------------------

-- Respond to thumbnail requests from the OSC.
local function on_thumbnailer_request(_, req)
    if req == nil then
        overlay_enabled = false
        pending_req = nil
        mp.command_native({"overlay-remove", OVERLAY_ID})
        return
    end
    if not sb then return end

    overlay_enabled = true
    if extracting then
        pending_req = req   -- drop the previous pending request
    else
        extracting = true
        do_show_thumbnail(req)
    end
end

-- Watch for the yt-dlp JSON result that ytdl_hook.lua stores.  This fires
-- during the on_load hook, before file-loaded, giving us everything we need
-- to kick off the storyboard download.
local function on_ytdl_result(_, result)
    if not result then return end

    local json_str = result.stdout
    if not json_str or json_str == "" then return end

    local json, parse_err = utils.parse_json(json_str)
    if not json then
        msg.debug("Could not parse ytdl JSON: " .. (parse_err or "?"))
        return
    end

    -- Only proceed for YouTube content.
    local extractor = (json.extractor_key or json.extractor or ""):lower()
    if not extractor:match("youtube") then return end

    -- Find preferred storyboard format: sb0 (180p) preferred, sb1 (90p) fallback.
    local sb_fmt_id = nil
    for _, fmt in ipairs(json.formats or {}) do
        if fmt.format_id == "sb0" then
            sb_fmt_id = "sb0"
            break
        elseif fmt.format_id == "sb1" then
            sb_fmt_id = "sb1"
        end
    end
    if not sb_fmt_id then
        msg.verbose("No storyboard format available for this video")
        return
    end

    local url  = json.webpage_url or json.original_url
    local ytdl = mp.get_property_native("user-data/mpv/ytdl/path")
    if not url or not ytdl or ytdl == "" then return end

    sb           = nil  -- clear any stale storyboard from a previous file
    pending_req  = nil
    extracting   = false
    local mhtml_path = utils.join_path(get_tmpdir(), "storyboard.mhtml")

    msg.verbose("Downloading YouTube storyboard (" .. sb_fmt_id .. ") for: " .. url)

    mp.command_native_async({
        name          = "subprocess",
        args          = {ytdl, "--no-warnings", "-f", sb_fmt_id, "-o", mhtml_path, "--", url},
        capture_stderr = true,
        playback_only  = false,
    }, function(success, dl_result)
        if not success or dl_result.status ~= 0 then
            msg.warn("Storyboard download failed: " ..
                (dl_result.stderr or ""))
            return
        end

        msg.verbose("Parsing storyboard mhtml...")
        local num_sprites = parse_mhtml(mhtml_path)
        if num_sprites == 0 then
            msg.warn("No sprite images found in storyboard mhtml")
            return
        end

        setup_storyboard(json, sb_fmt_id, num_sprites)
    end)
end

mp.observe_property("user-data/osc/thumbnailer", "native", on_thumbnailer_request)
mp.observe_property("user-data/mpv/ytdl/json-subprocess-result", "native", on_ytdl_result)

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------

-- On exit, remove the temporary directory with all cached sprites.
mp.register_event("shutdown", function()
    if not tmpdir then return end
    -- Sanity-check that the path looks like our own temp dir before deleting.
    if not tmpdir:find("mpv-yt-thumb-", 1, true) then return end
    if mp.get_property_native("platform") == "windows" then
        mp.command_native({
            name          = "subprocess",
            args          = {"cmd", "/c", "rmdir", "/s", "/q", tmpdir},
            playback_only = false,
        })
    else
        mp.command_native({
            name          = "subprocess",
            args          = {"rm", "-rf", "--", tmpdir},
            playback_only = false,
        })
    end
end)
