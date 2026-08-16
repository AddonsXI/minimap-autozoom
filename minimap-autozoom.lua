--[[
* Addons - Copyright (c) 2026 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
*
* minimap-autozoom was inspired by lin's minimap-helper,
* https://github.com/mousseng/xitools, which sets the zoom from a value you
* type. This one records the zoom as you use it instead.
--]]

addon.name      = 'minimap-autozoom';
addon.author    = 'AddonsXI';
addon.version   = '1.1.0';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'Automatically remembers the minimap zoom level you set in each zone';

require('common');

local ZONE_PACKET     = 0x0A;
local WM_MOUSEWHEEL   = 522;
local IDLE_SAVE_DELAY = 3000;
local DEFAULT_ZOOM    = '0.5';

-- The Minimap plugin clamps to 0.1, so anything at or under it was never a real zoom..
local MIN_ZOOM        = 0.1;
local POLL_DELAY      = 500;

-- Real zone ids stop around 300. Higher keys are leftovers from an older mog house design..
local MAX_ZONE        = 9999;
local HELPER_ADDON    = 'minimap-helper';
local SHARED_FILE     = 'zones.lua';

local zones      = { };
local dirty      = { };
local currentKey = nil;
local idleSaveAt = nil;
local pollAt     = 0;

local function InstallRoot()
    return AshitaCore:GetInstallPath():gsub('[\\/]+$', '');
end

local function AddonConfigDir(name)
    return ('%s\\config\\addons\\%s'):format(InstallRoot(), name);
end

local function SharedPath()
    return ('%s\\%s'):format(AddonConfigDir(addon.name), SHARED_FILE);
end

local function GetMinimapConfigPath()
    return ('%s\\config\\minimap\\minimap.ini'):format(InstallRoot());
end

--[[
* Reads the live zoom out of the Minimap plugin's own ini.
*
* The plugin's command list is set only, with no way to ask it for the current
* value, so the file is the only place the zoom can be read from. It rewrites
* the ini within about 200ms of every wheel notch, so this is current.
--]]
local function ReadCurrentZoom()
    local file = io.open(GetMinimapConfigPath(), 'r');
    if (file == nil) then
        return nil;
    end

    local section = nil;
    local zoom = nil;

    for line in file:lines() do
        local header = line:match('^%s*%[([^%]]+)%]');

        if (header ~= nil) then
            section = header:lower();
        elseif (section == 'main') then
            local value = line:match('^%s*zoom%s*=%s*([%d%.]+)');

            if (value ~= nil) then
                zoom = tonumber(value);
                break;
            end
        end
    end

    file:close();
    return zoom;
end

--[[
* Reads a settings file into a zone table, dropping anything unusable.
*
* Both filters matter: a zoom under the plugin's floor does nothing if restored,
* and a key above MAX_ZONE is dead data from an older design. Filtering on read
* means an existing file cleans itself up the next time it is written.
--]]
local function ReadZonesFrom(path)
    local file = io.open(path, 'r');
    if (file == nil) then
        return nil, 0;
    end

    local found = { };
    local count = 0;

    for line in file:lines() do
        local key, value = line:match('^%s*settings%[(%d+)%]%s*=%s*"([^"]*)"');
        local id = tonumber(key);

        if (id ~= nil and id <= MAX_ZONE and (tonumber(value) or 0) >= MIN_ZOOM) then
            found[id] = value;
            count = count + 1;
        end
    end

    file:close();
    return found, count;
end

--[[
* Writes a zone table out in the settings library's own format.
*
* Nothing loads this through that library any more, but keeping the format means
* the file stays readable, hand editable, and parseable by the same match above.
--]]
local function WriteZones(path, source)
    local keys = { };
    for key in pairs(source) do
        keys[#keys + 1] = key;
    end
    table.sort(keys);

    local file = io.open(path, 'w');
    if (file == nil) then
        return false;
    end

    file:write('require(\'common\');\n\nlocal settings = T{ };\n');

    for _, key in ipairs(keys) do
        file:write(('settings[%d] = "%s";\n'):format(key, source[key]));
    end

    file:write('\nreturn settings;\n');
    file:close();
    return true;
end

--[[
* Collects every character's saved zones from one addon's config folder.
*
* The name_id pattern is what separates a character folder from the settings
* library's own 'defaults' folder sitting beside them.
--]]
local function CollectFrom(addonName)
    local base = AddonConfigDir(addonName);
    local found = { };

    local entries = ashita.fs.get_directory(base, '.*');
    if (entries == nil) then
        return found;
    end

    for _, entry in ipairs(entries) do
        if (entry:match('^.+_%d+$') ~= nil) then
            local saved, count = ReadZonesFrom(('%s\\%s\\settings.lua'):format(base, entry));

            if (saved ~= nil and count > 0) then
                found[#found + 1] = { zones = saved, count = count };
            end
        end
    end

    return found;
end

--[[
* Folds every character's old per character file into one shared list.
*
* Runs once, on the first load where the shared file is missing. Sources are
* sorted smallest first so the character with the most saved zones overwrites
* the others and wins any conflict. The old files are left alone, which also
* means deleting the shared file re-runs this cleanly.
--]]
local function Migrate()
    local shared = SharedPath();

    if (ashita.fs.exists(shared)) then
        return;
    end

    local sources = { };

    for _, source in ipairs(CollectFrom(addon.name)) do
        sources[#sources + 1] = source;
    end

    for _, source in ipairs(CollectFrom(HELPER_ADDON)) do
        sources[#sources + 1] = source;
    end

    table.sort(sources, function(a, b) return a.count < b.count; end);

    local merged = { };
    local total = 0;

    for _, source in ipairs(sources) do
        for key, value in pairs(source.zones) do
            if (merged[key] == nil) then
                total = total + 1;
            end

            merged[key] = value;
        end
    end

    -- Create each segment in turn, since config\addons may not exist on a fresh install..
    local dir = AddonConfigDir(addon.name);
    if (not ashita.fs.exists(dir)) then
        local partial = '';
        for segment in dir:gmatch('[^\\]+') do
            partial = (#partial == 0) and segment or (partial .. '\\' .. segment);
            ashita.fs.create_directory(partial);
        end
    end

    -- A new player has nothing to merge, so say nothing at all..
    if (WriteZones(shared, merged) and total > 0) then
        print(('[%s] %d zones are now shared across all your characters.'):format(addon.name, total));
    end
end

--[[
* Re-reads the shared file, keeping any zone this session has changed.
*
* Picks up zones saved by a second client running alongside this one.
--]]
local function RefreshFromDisk()
    local disk = ReadZonesFrom(SharedPath());

    if (disk == nil) then
        return;
    end

    for key in pairs(dirty) do
        disk[key] = zones[key];
    end

    zones = disk;
end

--[[
* Writes changed zones back to the shared file.
*
* Merges onto what is on disk rather than overwriting it, and only for keys this
* session actually touched. Without that, a second client saving after us would
* lose whatever we had just written, and we would lose whatever it had.
--]]
local function SaveZones()
    if (next(dirty) == nil) then
        return;
    end

    local disk = ReadZonesFrom(SharedPath()) or { };

    for key in pairs(dirty) do
        disk[key] = zones[key];
    end

    if (WriteZones(SharedPath(), disk)) then
        zones = disk;
        dirty = { };
    end
end

local function CurrentKey()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);

    -- Zone reads 0 mid transition, which is not a place to save anything against..
    if (zone == nil or zone == 0) then
        return nil;
    end

    return zone;
end

local function StoreZoom(key)
    if (key == nil) then
        return;
    end

    local zoom = ReadCurrentZoom();
    if (zoom == nil or zoom < MIN_ZOOM) then
        return;
    end

    local value = ('%g'):format(zoom);
    if (zones[key] ~= value) then
        zones[key] = value;
        dirty[key] = true;
        SaveZones();
    end
end

local function RestoreZoom(key)
    if (key == nil) then
        return;
    end

    local zoom = zones[key];
    if (zoom == nil or (tonumber(zoom) or 0) < MIN_ZOOM) then
        zoom = DEFAULT_ZOOM;
    end

    AshitaCore:GetChatManager():QueueCommand(1, ('/minimap zoom %s'):format(zoom));
end

--[[
* Banks the zone being left, then applies the zone being entered.
*
* Storing before the key changes is what makes a zone change safe to lose the
* pending idle save to, since the value has already been written by then.
--]]
local function SwitchTo(key)
    if (key == nil or key == currentKey) then
        return;
    end

    if (currentKey ~= nil) then
        StoreZoom(currentKey);
    end

    idleSaveAt = nil;
    currentKey = key;

    RefreshFromDisk();
    RestoreZoom(key);
end

--[[
* event: load
* desc : Event called when the addon is being loaded.
--]]
ashita.events.register('load', 'load_cb', function ()
    Migrate();
    RefreshFromDisk();
    SwitchTo(CurrentKey());
end);

--[[
* event: packet_in
* desc : Event called when the client is receiving a packet.
--]]
ashita.events.register('packet_in', 'packet_in_cb', function (e)
    -- Treated as a nudge to poll early rather than parsed, since the party
    -- memory already carries the zone by the time the next frame runs..
    if (e.id == ZONE_PACKET) then
        pollAt = 0;
    end
end);

--[[
* event: mouse
* desc : Event called when the mouse is being used.
--]]
ashita.events.register('mouse', 'mouse_cb', function (e)
    -- Each notch pushes the deadline back, so a burst of scrolling saves once..
    if (e.message == WM_MOUSEWHEEL) then
        idleSaveAt = ashita.time.get_tick() + IDLE_SAVE_DELAY;
    end
end);

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    local now = ashita.time.get_tick();

    if (now >= pollAt) then
        pollAt = now + POLL_DELAY;
        SwitchTo(CurrentKey());
    end

    if (idleSaveAt ~= nil and now >= idleSaveAt) then
        idleSaveAt = nil;
        StoreZoom(currentKey);
    end
end);

--[[
* event: unload
* desc : Event called when the addon is being unloaded.
--]]
ashita.events.register('unload', 'unload_cb', function ()
    -- Catches a zoom set and never zoned away from..
    StoreZoom(currentKey);
end);
