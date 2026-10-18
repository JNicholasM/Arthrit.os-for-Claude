-- Arthrit.os installer disk.
-- CC runs a disk's startup instead of the computer's own when the computer
-- boots with the disk inserted. This installs or updates Arthrit.os if the
-- computer doesn't already have this version, then starts it. It never
-- replaces a newer version with an older one.
--
-- The OS can be split over several disks (parts.txt says "<this disk> <count>",
-- each disk holds one piece of arthrit.pak). Any of them starts the install;
-- it asks for the others, in any disk drive, one after another or all at once.
--
-- Updating keeps the computer's settings, controllers, desktop layout, app
-- shortcuts and icons (arthrit/data is only added if missing). On the next
-- boot arthrit/sys/upgrade.lua brings shortcuts and controllers up to date.
--
-- The same file, with WEB set to a download address, installs from the
-- internet instead (release/install.lua: "wget run <address>/install.lua").
local WEB = "https://raw.githubusercontent.com/JNicholasM/Arthrit.os-for-Claude/main/release"
local DISK = not WEB and fs.getDir(shell.getRunningProgram())

-- Downloads one file of the release. Returns its contents or nil, error.
local function fetch(name, binary)
    if not http then return nil, "This server doesn't allow computers to use the internet" end
    local response, err = http.get(WEB .. "/" .. name .. "?t=" .. os.epoch("utc"), nil, binary)
    if not response then return nil, err or "Download failed" end
    local data = response.readAll()
    response.close()
    return data
end

local function readFile(p, binary)
    local f = fs.open(p, binary and "rb" or "r")
    if not f then return nil end
    local data = f.readAll()
    f.close()
    return data
end

local function writeFile(p, data)
    local dir = fs.getDir(p)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(p, "wb")
    if not f then return false end
    f.write(data)
    f.close()
    return true
end

-- Yields now and then so long work doesn't trip CC's "too long without yielding".
local lastYield = os.clock()
local function breathe()
    if os.clock() - lastYield > 2 then
        os.queueEvent("arthrit_installer")
        os.pullEvent("arthrit_installer")
        lastYield = os.clock()
    end
end

-- LZW decoder matching dev-tools/make_disk.py.
local function decompress(data, onProgress)
    local dict, size = {}, 256
    for i = 0, 255 do dict[i] = string.char(i) end
    local out, pos, buf, nbits, i, prev = {}, 1, 0, 0, 0, nil
    local total = #data
    local width, limit = 9, 512 -- code i uses as many bits as 256 + i needs, at most 16
    while true do
        if 256 + i >= limit and width < 16 then width, limit = width + 1, limit * 2 end
        while nbits < width do
            if pos > total then return table.concat(out) end
            buf = buf + data:byte(pos) * 2 ^ nbits
            pos, nbits = pos + 1, nbits + 8
        end
        local code = buf % 2 ^ width
        buf, nbits = math.floor(buf / 2 ^ width), nbits - width
        local entry
        if prev == nil then
            entry = dict[code]
        else
            entry = dict[code] or (prev .. prev:sub(1, 1))
            if size < 65536 then
                dict[size] = prev .. entry:sub(1, 1)
                size = size + 1
            end
        end
        if not entry then error("Installer disk is damaged") end
        out[#out + 1] = entry
        prev, i = entry, i + 1
        if i % 2000 == 0 then
            breathe()
            if onProgress then onProgress(pos / total) end
        end
    end
end

local function unpack(archive)
    assert(archive:sub(1, 12) == "ARTHRITPAK1\n", "Installer disk is damaged")
    local files, pos = {}, 13
    while pos <= #archive do
        local pathEnd = archive:find("\n", pos, true)
        local sizeEnd = archive:find("\n", pathEnd + 1, true)
        local path = archive:sub(pos, pathEnd - 1)
        local size = tonumber(archive:sub(pathEnd + 1, sizeEnd - 1))
        files[#files + 1] = { path = path, data = archive:sub(sizeEnd + 1, sizeEnd + size) }
        pos = sizeEnd + size + 1
    end
    return files
end

-- Files the user may have changed: only written if they don't exist yet.
local function keepIfPresent(path)
    return path:match("^arthrit/data/") or path:match("^arthrit/apps/") or path:match("^arthrit/icons/")
end

-- "0.3-202610170415" -> true if a is older than b
local function older(a, b)
    local function key(v)
        local k = {}
        for n in v:gsub("%-.*", ""):gmatch("%d+") do k[#k + 1] = tonumber(n) end
        k[#k + 1] = tonumber(v:match("%-(%d+)") or 0)
        return k
    end
    local ka, kb = key(a), key(b)
    for i = 1, math.max(#ka, #kb) do
        if (ka[i] or 0) ~= (kb[i] or 0) then return (ka[i] or 0) < (kb[i] or 0) end
    end
    return false
end

local function trim(s) return s and (s:gsub("%s+$", "")) end

-- This disk's version and "<n> <count>".
local function diskInfo(mount)
    local v = trim(readFile(fs.combine(mount, "version.txt")))
    local n, count = (readFile(fs.combine(mount, "parts.txt")) or "1 1"):match("(%d+)%s+(%d+)")
    return v, tonumber(n) or 1, tonumber(count) or 1
end

local function bar(fraction, label)
    local w, h = term.getSize()
    local width = math.max(10, w - 4)
    term.setCursorPos(3, h - 2)
    term.setBackgroundColor(colors.gray)
    term.write((" "):rep(width))
    term.setCursorPos(3, h - 2)
    term.setBackgroundColor(colors.cyan)
    term.write((" "):rep(math.floor(width * math.min(1, fraction))))
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.setCursorPos(3, h - 4)
    term.clearLine()
    term.write(label)
end

local function header(version, installed)
    term.setBackgroundColor(colors.blue)
    term.clear()
    term.setTextColor(colors.white)
    term.setCursorPos(3, 2)
    term.write("Arthrit.os " .. version)
    term.setCursorPos(3, 3)
    term.setTextColor(colors.lightGray)
    term.write(installed and ("Updating from " .. installed) or "Installing")
end

-- Reads every piece of arthrit.pak, asking for disks that aren't inserted
-- (or downloads it).
local function gatherPak(version, count, installed)
    if WEB then
        header(version, installed)
        bar(0, "Downloading...")
        local data, err = fetch("arthrit.pak", true)
        if not data then error("Download failed: " .. tostring(err)) end
        return data
    end
    local pieces, have = {}, 0
    local function scan()
        for _, side in ipairs(peripheral.getNames()) do
            local mount = disk.isPresent(side) and disk.getMountPath(side)
            if mount then
                local v, n = diskInfo(mount)
                if v == version and not pieces[n] then
                    local data = readFile(fs.combine(mount, "arthrit.pak"), true)
                    if data then pieces[n], have = data, have + 1 end
                end
            end
        end
    end
    scan()
    while have < count do
        local missing = {}
        for n = 1, count do if not pieces[n] then missing[#missing + 1] = n end end
        header(version, installed)
        term.setTextColor(colors.white)
        term.setCursorPos(3, 5)
        term.write(("Insert installer disk %d of %d"):format(missing[1], count))
        term.setCursorPos(3, 6)
        term.setTextColor(colors.lightGray)
        term.write("(any disk drive; take the other one out first")
        term.setCursorPos(3, 7)
        term.write(" if there is only one drive)")
        term.setCursorPos(3, 9)
        term.write("Press Q to skip installing")
        local e, p = os.pullEvent()
        if e == "disk" then
            scan()
        elseif e == "char" and (p == "q" or p == "Q") then
            return nil
        end
    end
    return table.concat(pieces)
end

local function install(version, installed, count)
    local pak = gatherPak(version, count, installed)
    if not pak then return false end
    header(version, installed)
    bar(0, "Unpacking...")
    local files = unpack(decompress(pak, function(f) bar(f * 0.8, "Unpacking...") end))

    local needed = 0
    for _, f in ipairs(files) do needed = needed + #f.data end
    if fs.getFreeSpace("/") < needed then
        error("Not enough space on this computer (" .. math.ceil(needed / 1024) .. " KB needed)")
    end

    -- Keep a non-Arthrit startup the computer already had.
    local oldStartup = readFile("/startup.lua")
    if oldStartup and not oldStartup:find("arthrit", 1, true) then
        writeFile("/startup.before-arthrit.lua", oldStartup)
    end

    for n, f in ipairs(files) do
        if f.path ~= "arthrit/version.txt" and not (keepIfPresent(f.path) and fs.exists("/" .. f.path)) then
            if not writeFile("/" .. f.path, f.data) then error("Could not write " .. f.path) end
        end
        if n % 10 == 0 then
            bar(0.8 + 0.2 * n / #files, "Copying files...")
            breathe()
        end
    end
    writeFile("/arthrit/version.txt", version) -- written last: a half-finished install retries next boot
    bar(1, "Done!")
    sleep(0.5)
    return true
end

local version, count
if WEB then
    local v, err = fetch("version.txt")
    if not v then
        printError("Couldn't reach the download: " .. tostring(err))
        return
    end
    version, count = trim(v), 1
else
    version, _, count = diskInfo(DISK)
end
local installed = trim(readFile("/arthrit/version.txt"))
if WEB and version == installed then
    print("Arthrit.os " .. version .. " is already installed here.")
    return
end
if version and installed and version ~= installed and older(version, installed) then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("This disk has Arthrit.os " .. version .. ",")
    print("older than the installed " .. installed .. ". Not installing it.")
    sleep(2)
    if WEB then return end
elseif version and version ~= installed then
    local ok, err = pcall(install, version, installed, count)
    if not ok then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
        printError("Arthrit.os install failed: " .. tostring(err))
        print(WEB and "Press any key." or "Remove the disk and press any key for the normal shell.")
        os.pullEvent("key")
        return
    end
    if WEB then
        -- installed from the internet: start the new version
        os.reboot()
    end
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
shell.run("/startup.lua")
